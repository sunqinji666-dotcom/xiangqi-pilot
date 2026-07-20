import AppKit
import CoreGraphics
import Foundation
import XiangqiCore

/// Single-intersection counterpart to `ClickExecutor`.  Grid games place a
/// stone with one click, so a source/destination pair would be an unsafe
/// abstraction.  This actor owns the same permission, target, geometry and
/// fresh-frame gates before emitting that one click.
struct GridClickReceipt: Hashable, Sendable {
    let actionID: UUID
    let ownerPID: pid_t
    let windowID: CGWindowID
    let beforeFrameSequence: UInt64
    let beforeFingerprint: UInt64
    let point: GridCoordinate
    let dispatchedAt: TimeInterval
}

enum GridClickExecutorError: LocalizedError, Equatable {
    case notArmed
    case actionInFlight
    case permissionMissing
    case targetMissing
    case targetNotFrontmost
    case targetChanged
    case geometryChanged
    case staleFrame
    case pointOutsideTarget
    case eventCreationFailed
    case verificationUnchanged

    var errorDescription: String? {
        switch self {
        case .notArmed: "网格落子尚未启用"
        case .actionInFlight: "已有网格落子正在等待验证"
        case .permissionMissing: "缺少屏幕录制或辅助功能权限"
        case .targetMissing: "目标窗口已消失"
        case .targetNotFrontmost: "目标窗口无法置前"
        case .targetChanged: "目标窗口已变化"
        case .geometryChanged: "棋盘标定几何已过期"
        case .staleFrame: "落子前画面已过期"
        case .pointOutsideTarget: "落点不在锁定窗口安全区域"
        case .eventCreationFailed: "无法创建系统点击事件"
        case .verificationUnchanged: "单击后棋盘画面未变化"
        }
    }
}

actor GridClickExecutor {
    private var armed = false
    private var pending: GridClickReceipt?

    func arm() throws {
        guard pending == nil else { throw GridClickExecutorError.actionInFlight }
        armed = true
    }

    func pause() {
        armed = false
        pending = nil
    }

    func executeTap(
        at coordinate: GridCoordinate,
        calibration: GridBoardCalibration,
        capture: WindowCaptureService
    ) async throws -> GridClickReceipt {
        guard armed else { throw GridClickExecutorError.notArmed }
        guard pending == nil else { throw GridClickExecutorError.actionInFlight }
        guard MacPermissionsService.screenRecordingStatus == .granted,
              MacPermissionsService.accessibilityStatus == .granted else {
            throw GridClickExecutorError.permissionMissing
        }
        guard let target = await capture.lockedTarget(),
              let application = NSRunningApplication(processIdentifier: target.ownerPID) else {
            throw GridClickExecutorError.targetMissing
        }
        guard let initial = try? await capture.latestFrame(),
              initial.target.ownerPID == target.ownerPID,
              initial.target.windowID == target.windowID,
              let initialFrame = initial.liveWindowGeometry?.frame,
              abs(initialFrame.width - calibration.windowFrame.width) <= 0.5,
              abs(initialFrame.height - calibration.windowFrame.height) <= 0.5 else {
            throw GridClickExecutorError.geometryChanged
        }

        guard await Self.activateLockedTarget(
            application: application,
            ownerPID: target.ownerPID,
            expectedFrame: initialFrame
        ) else {
            throw GridClickExecutorError.targetNotFrontmost
        }
        // Activating an iOS-on-Mac window can temporarily pause its
        // ScreenCaptureKit delivery. A single immediate read therefore races
        // the first fresh frame and used to stop a rapid "both sides" test
        // after a few perfectly valid moves. Wait briefly for a *new* frame;
        // this keeps the stale-frame safety gate intact instead of accepting
        // the pre-activation image.
        let freshClock = ContinuousClock()
        let freshDeadline = freshClock.now.advanced(by: .milliseconds(650))
        var freshFrame: CapturedFrame?
        var freshLiveFrame: CGRect?
        while freshClock.now < freshDeadline {
            if let candidate = try? await capture.latestFrame(),
               candidate.sequence > initial.sequence,
               candidate.target.ownerPID == target.ownerPID,
               candidate.target.windowID == target.windowID,
               let candidateLive = candidate.liveWindowGeometry?.frame,
               abs(candidateLive.width - calibration.windowFrame.width) <= 0.5,
               abs(candidateLive.height - calibration.windowFrame.height) <= 0.5 {
                freshFrame = candidate
                freshLiveFrame = candidateLive
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let fresh = freshFrame, let live = freshLiveFrame else {
            throw GridClickExecutorError.staleFrame
        }
        let point = try calibration.globalScreenPoint(for: coordinate, in: live)
        guard live.insetBy(dx: 2, dy: 2).contains(point) else { throw GridClickExecutorError.pointOutsideTarget }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw GridClickExecutorError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(22))
        up.post(tap: .cghidEventTap)
        let receipt = GridClickReceipt(
            actionID: UUID(), ownerPID: target.ownerPID, windowID: target.windowID,
            beforeFrameSequence: fresh.sequence, beforeFingerprint: fresh.contentFingerprint,
            point: coordinate, dispatchedAt: ProcessInfo.processInfo.systemUptime
        )
        pending = receipt
        return receipt
    }

    func verify(_ receipt: GridClickReceipt, capture: WindowCaptureService) async throws {
        guard pending?.actionID == receipt.actionID else { throw GridClickExecutorError.actionInFlight }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let frame = try? await capture.latestFrame(),
               frame.target.ownerPID == receipt.ownerPID,
               frame.target.windowID == receipt.windowID,
               frame.sequence > receipt.beforeFrameSequence,
               frame.contentFingerprint != receipt.beforeFingerprint {
                pending = nil
                armed = true
                return
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        pending = nil
        armed = false
        throw GridClickExecutorError.verificationUnchanged
    }

    /// Performs the foreground handoff as part of a cockpit-confirmed action.
    /// iOS-on-macOS targets often acknowledge `activate` without becoming
    /// frontmost, so use the normal Workspace activation route, then the
    /// already-authorized AX raise route, and prove the handoff by PID.
    static func activateLockedTarget(
        application: NSRunningApplication,
        ownerPID: pid_t,
        expectedFrame: CGRect
    ) async -> Bool {
        if await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
        }) {
            return true
        }

        await MainActor.run {
            NSApp.yieldActivation(to: application)
            _ = application.activate(options: [.activateAllWindows])
        }
        try? await Task.sleep(for: .milliseconds(140))
        if await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
        }) {
            return true
        }

        if let bundleURL = application.bundleURL {
            let opened = await activateThroughWorkspace(
                at: bundleURL,
                expectedPID: ownerPID
            )
            if opened { try? await Task.sleep(for: .milliseconds(180)) }
        }
        if await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
        }) {
            return true
        }

        _ = await MainActor.run {
            raiseLockedWindow(ownerPID: ownerPID, expectedFrame: expectedFrame)
        }
        try? await Task.sleep(for: .milliseconds(160))
        return await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
        }
    }

    @MainActor
    private static func activateThroughWorkspace(
        at bundleURL: URL,
        expectedPID: pid_t
    ) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
                openedApplication, error in
                continuation.resume(
                    returning: error == nil
                        && openedApplication?.processIdentifier == expectedPID
                )
            }
        }
    }

    @MainActor
    private static func raiseLockedWindow(ownerPID: pid_t, expectedFrame: CGRect) -> Bool {
        let application = AXUIElementCreateApplication(ownerPID)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
              let windows = rawWindows as? [AXUIElement],
              let target = windows.first(where: { matchesFrame($0, expectedFrame: expectedFrame) }) else {
            return false
        }

        _ = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            target,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            target,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    private static func matchesFrame(_ element: AXUIElement, expectedFrame: CGRect) -> Bool {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return false
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return false
        }
        let frame = CGRect(origin: origin, size: size)
        let tolerance: CGFloat = 3
        return abs(frame.minX - expectedFrame.minX) <= tolerance
            && abs(frame.minY - expectedFrame.minY) <= tolerance
            && abs(frame.width - expectedFrame.width) <= tolerance
            && abs(frame.height - expectedFrame.height) <= tolerance
    }
}
