import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

/// TCC does not expose whether a missing permission has never been requested or
/// was denied. Keep that distinction out of the API so callers do not present a
/// misleading state to the user.
enum MacPermissionStatus: Sendable, Equatable {
    case granted
    case notGranted
}

enum MacPermissionKind: String, Sendable, Hashable {
    case screenRecording
    case accessibility
}

/// The identity macOS TCC associates with the currently running executable.
/// An ad-hoc signature has a designated requirement based on its changing
/// cdhash, so grants normally stop matching after every rebuild/re-sign.
struct PermissionCodeIdentity: Sendable, Equatable {
    let bundleIdentifier: String?
    let signingIdentifier: String?
    let teamIdentifier: String?
    let cdHash: String?
    let executablePath: String
    let bundlePath: String
    let isPackagedApplication: Bool
    let isAdHocSigned: Bool

    var isStableForTCC: Bool {
        isPackagedApplication && !isAdHocSigned && signingIdentifier != nil
    }
}

struct MacPermissionSnapshot: Sendable, Equatable {
    let screenRecording: MacPermissionStatus
    let accessibility: MacPermissionStatus
    let checkedAt: Date
    let codeIdentity: PermissionCodeIdentity

    /// True only when the system request returned success but the current
    /// process still fails preflight. In that narrow state the safe recovery is
    /// relaunching the same signed .app, not requesting permission again.
    let screenRecordingMayRequireRelaunch: Bool

    var allGranted: Bool {
        screenRecording == .granted && accessibility == .granted
    }
}

extension Notification.Name {
    /// Posted on the main queue when either effective permission changes. UI
    /// may observe this in addition to polling while its permission sheet is up.
    static let macPermissionsDidRefresh = Notification.Name(
        "com.jacksun.xiangqi-pilot.permissions-did-refresh"
    )
}

enum MacPermissionsService {
    static var screenRecordingStatus: MacPermissionStatus {
        currentSnapshot().screenRecording
    }

    static var accessibilityStatus: MacPermissionStatus {
        currentSnapshot().accessibility
    }

    /// Always queries the public TCC APIs again; no grant result is cached as
    /// authoritative. This avoids presenting a stale launch-time value after
    /// the user returns from System Settings.
    static func currentSnapshot() -> MacPermissionSnapshot {
        _ = lifecycleObserver

        let screenGranted = CGPreflightScreenCaptureAccess()
        let accessibilityGranted = AXIsProcessTrusted()
        let snapshot = MacPermissionSnapshot(
            screenRecording: screenGranted ? .granted : .notGranted,
            accessibility: accessibilityGranted ? .granted : .notGranted,
            checkedAt: Date(),
            codeIdentity: currentCodeIdentity(),
            screenRecordingMayRequireRelaunch:
                requestState.screenRequestReturnedGranted && !screenGranted
        )

        if requestState.record(snapshot) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .macPermissionsDidRefresh,
                    object: snapshot
                )
            }
        }
        return snapshot
    }

    /// Requests Screen Recording access. macOS may require the app to be
    /// restarted after the user changes this permission in System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard requestState.beginRequest(.screenRecording) else { return false }
        defer { requestState.endRequest(.screenRecording) }

        let result = CGRequestScreenCaptureAccess()
        requestState.recordScreenRequestResult(result)
        _ = currentSnapshot()
        return result
    }

    /// Shows the system Accessibility prompt and returns the status known at
    /// the time of the call. Granting access in Settings can happen later, so
    /// callers should continue polling `accessibilityStatus` while paused.
    @discardableResult
    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard requestState.beginRequest(.accessibility) else { return false }
        defer { requestState.endRequest(.accessibility) }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)
        _ = currentSnapshot()
        return result
    }

    private static let requestState = PermissionRequestState()

    /// SwiftUI tasks normally poll while the setup sheet is visible. This
    /// observer also refreshes after returning from System Settings and makes
    /// the service usable by lifecycle code that does not poll continuously.
    private static let lifecycleObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
    ) { _ in
        _ = MacPermissionsService.currentSnapshot()
    }

    private static func currentCodeIdentity() -> PermissionCodeIdentity {
        let bundle = Bundle.main
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let executableURL = bundle.executableURL?.standardizedFileURL
        let expectedExecutableDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .path + "/"
        let executablePath = executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? ""
        let isPackagedApplication = bundleURL.pathExtension.lowercased() == "app"
            && executablePath.hasPrefix(expectedExecutableDirectory)

        var signingIdentifier: String?
        var teamIdentifier: String?
        var cdHash: String?
        var isAdHocSigned = false

        var staticCode: SecStaticCode?
        let codeURL = isPackagedApplication ? bundleURL : (executableURL ?? bundleURL)
        if SecStaticCodeCreateWithPath(codeURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
           let staticCode {
            var rawInformation: CFDictionary?
            let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
            if SecCodeCopySigningInformation(staticCode, flags, &rawInformation) == errSecSuccess,
               let information = rawInformation as NSDictionary? {
                signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String
                teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
                if let unique = information[kSecCodeInfoUnique as String] as? Data {
                    cdHash = unique.map { String(format: "%02x", $0) }.joined()
                }
                if let signatureFlags = information[kSecCodeInfoFlags as String] as? NSNumber {
                    // kSecCodeSignatureAdhoc is declared in CSCommon.h but is
                    // not imported into every Swift SDK overlay.
                    let adHocSignatureFlag: UInt32 = 0x0002
                    isAdHocSigned = signatureFlags.uint32Value & adHocSignatureFlag != 0
                }
            }
        }

        return PermissionCodeIdentity(
            bundleIdentifier: bundle.bundleIdentifier,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: cdHash,
            executablePath: executablePath,
            bundlePath: bundleURL.path,
            isPackagedApplication: isPackagedApplication,
            isAdHocSigned: isAdHocSigned
        )
    }
}

private final class PermissionRequestState: @unchecked Sendable {
    private struct EffectiveState: Equatable {
        let screenRecording: MacPermissionStatus
        let accessibility: MacPermissionStatus
        let identityCDHash: String?
    }

    private let lock = NSLock()
    private var requestsInFlight: Set<MacPermissionKind> = []
    private var lastEffectiveState: EffectiveState?
    private var didScreenRequestReturnGranted = false

    var screenRequestReturnedGranted: Bool {
        lock.withPermissionLock { didScreenRequestReturnGranted }
    }

    func beginRequest(_ kind: MacPermissionKind) -> Bool {
        lock.withPermissionLock {
            requestsInFlight.insert(kind).inserted
        }
    }

    func endRequest(_ kind: MacPermissionKind) {
        _ = lock.withPermissionLock {
            requestsInFlight.remove(kind)
        }
    }

    func recordScreenRequestResult(_ granted: Bool) {
        lock.withPermissionLock {
            didScreenRequestReturnGranted = didScreenRequestReturnGranted || granted
        }
    }

    /// Returns true only for an effective state transition. `checkedAt` is
    /// intentionally excluded so one-second polling does not emit notifications
    /// forever.
    func record(_ snapshot: MacPermissionSnapshot) -> Bool {
        lock.withPermissionLock {
            let effective = EffectiveState(
                screenRecording: snapshot.screenRecording,
                accessibility: snapshot.accessibility,
                identityCDHash: snapshot.codeIdentity.cdHash
            )
            guard effective != lastEffectiveState else { return false }
            lastEffectiveState = effective
            return true
        }
    }
}

private extension NSLock {
    func withPermissionLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
