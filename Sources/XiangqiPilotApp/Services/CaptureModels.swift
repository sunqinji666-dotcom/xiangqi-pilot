import CoreGraphics
import Foundation

struct CapturableWindow: Identifiable, Hashable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    let frame: CGRect

    var id: CGWindowID { windowID }
}

struct LockedCaptureTarget: Hashable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    let frameAtLock: CGRect
}

struct LiveWindowGeometry: Hashable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

/// Metadata is deliberately rich enough to bind an action to an observed
/// frame. `contentFingerprint` is a cheap, quantized visual fingerprint; it is
/// a stale-frame guard, not a semantic board-state hash.
struct CapturedFrame {
    let image: CGImage
    let sequence: UInt64
    let presentationTime: TimeInterval
    let contentFingerprint: UInt64
    let consecutiveStableFrames: Int
    let imageSize: CGSize
    let target: LockedCaptureTarget
    let liveWindowGeometry: LiveWindowGeometry?

    func isStable(minimumConsecutiveFrames: Int = 2) -> Bool {
        consecutiveStableFrames >= minimumConsecutiveFrames
    }
}

enum WindowCaptureError: LocalizedError, Equatable {
    case screenRecordingPermissionMissing
    case windowNotFound(CGWindowID)
    case windowHasNoOwningApplication(CGWindowID)
    case invalidWindowSize
    case noLockedWindow
    case noFrameAvailable
    case streamStopped(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return "缺少屏幕录制权限"
        case let .windowNotFound(windowID):
            return "找不到窗口 \(windowID)"
        case let .windowHasNoOwningApplication(windowID):
            return "窗口 \(windowID) 没有所属应用"
        case .invalidWindowSize:
            return "窗口尺寸无效"
        case .noLockedWindow:
            return "尚未锁定捕获窗口"
        case .noFrameAvailable:
            return "捕获流尚未产生有效帧"
        case let .streamStopped(message):
            return "捕获流已停止：\(message)"
        }
    }
}
