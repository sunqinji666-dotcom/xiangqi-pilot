import AppKit
import CoreGraphics
import Foundation

enum AutomationPauseReason: Sendable, Equatable {
    case userRequested
    case manualTakeover
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case targetWindowMissing
    case targetNotFrontmost
    case targetWindowChanged
    case geometryChanged
    case frameUnstable
    case staleFrame
    case boardStateChanged
    case roiViolation
    case verificationFailed(String)
    case captureFailure(String)
    case inputFailure(String)
}

enum AutomationControlState: Sendable, Equatable {
    case paused(AutomationPauseReason)
    case armed
    case executing(UUID)
    case awaitingVerification(UUID)
    case manualTakeover
}

/// Immutable precondition token created from the exact stable frame used by the
/// recognizer/engine. A newer frame may still be accepted only when its cheap
/// visual fingerprint is unchanged and it is within `maximumFrameAdvance`.
struct ClickActionBinding: Hashable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let frameSequence: UInt64
    let frameContentFingerprint: UInt64
    let recognizedBoardStateHash: String
    let geometryHash: String
    let minimumStableFrames: Int
    let maximumFrameAdvance: UInt64

    init(
        ownerPID: pid_t,
        windowID: CGWindowID,
        frameSequence: UInt64,
        frameContentFingerprint: UInt64,
        recognizedBoardStateHash: String,
        geometryHash: String,
        minimumStableFrames: Int = 2,
        maximumFrameAdvance: UInt64 = 90
    ) {
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.frameSequence = frameSequence
        self.frameContentFingerprint = frameContentFingerprint
        self.recognizedBoardStateHash = recognizedBoardStateHash
        self.geometryHash = geometryHash
        self.minimumStableFrames = max(1, minimumStableFrames)
        self.maximumFrameAdvance = maximumFrameAdvance
    }
}

struct XiangqiClickMove: Hashable, Sendable {
    let source: XiangqiGridPoint
    let destination: XiangqiGridPoint
}

struct ClickExecutionReceipt: Hashable, Sendable {
    let actionID: UUID
    let ownerPID: pid_t
    let windowID: CGWindowID
    let geometryHash: String
    let source: XiangqiGridPoint
    let destination: XiangqiGridPoint
    let sourceScreenPoint: CGPoint
    let destinationScreenPoint: CGPoint
    let beforeFrameSequence: UInt64
    let beforeFrameFingerprint: UInt64
    let beforeBoardStateHash: String
    let calibratedWindowFrame: CGRect
    let calibratedImageSize: CGSize
    let dispatchedAtUptime: TimeInterval
    let minimumVerificationFrameSequence: UInt64
}

struct ClickVerification: Hashable, Sendable {
    let actionID: UUID
    let beforeFrameSequence: UInt64
    let afterFrameSequence: UInt64
    let afterFrameFingerprint: UInt64
    let afterBoardStateHash: String
    let verifiedAtUptime: TimeInterval
}

enum ClickExecutorError: LocalizedError, Equatable {
    case notArmed
    case anotherActionInFlight
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case targetMismatch
    case targetWindowMissing
    case targetNotOnScreen
    case unexpectedWindowLayer(Int)
    case targetNotFrontmost
    case targetWindowOccluded
    case geometryHashMismatch
    case windowGeometryChanged
    case imageGeometryChanged
    case frameOlderThanBinding
    case frameAdvancedTooFar
    case frameContentChanged
    case frameFingerprintUnavailable
    case frameNotStable
    case emptyBoardStateHash
    case sourceEqualsDestination
    case roiViolation
    case eventCreationFailed
    case interrupted
    case noMatchingPendingReceipt
    case verificationFrameMissing
    case verificationFrameUnstable
    case verificationSawNoVisualChange
    case verificationBoardStateUnchanged

    var errorDescription: String? {
        switch self {
        case .notArmed: return "自动执行尚未启用"
        case .anotherActionInFlight: return "已有动作正在执行或等待验证"
        case .accessibilityPermissionMissing: return "缺少辅助功能权限"
        case .screenRecordingPermissionMissing: return "缺少屏幕录制权限"
        case .targetMismatch: return "动作绑定的目标与捕获窗口不一致"
        case .targetWindowMissing: return "目标窗口已消失"
        case .targetNotOnScreen: return "目标窗口当前不可见"
        case let .unexpectedWindowLayer(layer): return "目标窗口层级异常：\(layer)"
        case .targetNotFrontmost: return "目标应用不是前台应用"
        case .targetWindowOccluded: return "目标落点被其他窗口遮挡"
        case .geometryHashMismatch: return "动作绑定的棋盘几何已过期"
        case .windowGeometryChanged: return "目标窗口已移动或缩放"
        case .imageGeometryChanged: return "捕获图像尺寸与校准不一致"
        case .frameOlderThanBinding: return "捕获帧早于动作绑定帧"
        case .frameAdvancedTooFar: return "动作绑定帧已过期"
        case .frameContentChanged: return "思考期间窗口画面已变化"
        case .frameFingerprintUnavailable: return "捕获帧缺少可用的视觉指纹"
        case .frameNotStable: return "捕获画面尚未稳定"
        case .emptyBoardStateHash: return "识别器没有提供棋局状态哈希"
        case .sourceEqualsDestination: return "起点和终点不能相同"
        case .roiViolation: return "点击坐标超出棋盘或窗口安全区域"
        case .eventCreationFailed: return "无法创建系统点击事件"
        case .interrupted: return "动作已被人工接管或异常暂停"
        case .noMatchingPendingReceipt: return "没有匹配的待验证动作"
        case .verificationFrameMissing: return "尚未捕获到动作后的新画面"
        case .verificationFrameUnstable: return "动作后的画面尚未稳定"
        case .verificationSawNoVisualChange: return "点击后没有检测到视觉变化"
        case .verificationBoardStateUnchanged: return "点击后棋局状态没有变化"
        }
    }
}

/// Serializes all injected input. The engine never receives this capability;
/// callers must supply a frame-bound token that has already passed chess-rule
/// validation in the upper layer.
actor ClickExecutor {
    private(set) var state: AutomationControlState = .paused(.userRequested)
    private(set) var pendingReceipt: ClickExecutionReceipt?

    private var safetyEpoch: UInt64 = 0
    private let mouseDownDurationNanoseconds: UInt64
    private let sourceToDestinationDelayNanoseconds: UInt64

    init(mouseDownMilliseconds: UInt64 = 18, sourceToDestinationDelayMilliseconds: UInt64 = 70) {
        mouseDownDurationNanoseconds = mouseDownMilliseconds * 1_000_000
        sourceToDestinationDelayNanoseconds = sourceToDestinationDelayMilliseconds * 1_000_000
    }

    func arm() throws {
        guard pendingReceipt == nil else { throw ClickExecutorError.anotherActionInFlight }
        safetyEpoch &+= 1
        state = .armed
    }

    func pause(_ reason: AutomationPauseReason = .userRequested) {
        safetyEpoch &+= 1
        pendingReceipt = nil
        state = .paused(reason)
    }

    /// Called by the UI as soon as the user takes over. No global event tap is
    /// installed, avoiding an extra Input Monitoring permission.
    func takeManualControl() {
        safetyEpoch &+= 1
        pendingReceipt = nil
        state = .manualTakeover
    }

    func execute(
        _ move: XiangqiClickMove,
        binding: ClickActionBinding,
        calibration: BoardCalibration,
        capture: WindowCaptureService
    ) async throws -> ClickExecutionReceipt {
        guard case .armed = state else {
            if pendingReceipt != nil { throw ClickExecutorError.anotherActionInFlight }
            throw ClickExecutorError.notArmed
        }
        guard pendingReceipt == nil else { throw ClickExecutorError.anotherActionInFlight }
        guard move.source != move.destination else { throw ClickExecutorError.sourceEqualsDestination }

        let actionID = UUID()
        let epoch = safetyEpoch
        state = .executing(actionID)

        do {
            let beforeFrame = try await capture.latestFrame()
            try ensureStillExecuting(actionID: actionID, epoch: epoch)
            try await validateBeforeClick(
                frame: beforeFrame,
                binding: binding,
                calibration: calibration
            )

            let sourcePoint = try calibration.globalScreenPoint(for: move.source)
            let destinationPoint = try calibration.globalScreenPoint(for: move.destination)
            try validatePoints(
                sourcePoint,
                destinationPoint,
                liveWindowFrame: beforeFrame.liveWindowGeometry?.frame,
                calibration: calibration,
                windowID: binding.windowID
            )

            try await postClick(at: sourcePoint, actionID: actionID, epoch: epoch)
            try await Task.sleep(nanoseconds: sourceToDestinationDelayNanoseconds)
            try ensureStillExecuting(actionID: actionID, epoch: epoch)

            // Re-check authority and geometry between the source selection and
            // destination click. A pause at this point leaves only a selected
            // piece; it does not send an unintended move.
            try await validateLiveTarget(
                capture: capture,
                binding: binding,
                calibration: calibration,
                actionID: actionID,
                epoch: epoch
            )
            guard Self.targetWindowIsTopmost(binding.windowID, at: [destinationPoint]) else {
                throw ClickExecutorError.targetWindowOccluded
            }
            try await postClick(at: destinationPoint, actionID: actionID, epoch: epoch)

            let receipt = ClickExecutionReceipt(
                actionID: actionID,
                ownerPID: binding.ownerPID,
                windowID: binding.windowID,
                geometryHash: binding.geometryHash,
                source: move.source,
                destination: move.destination,
                sourceScreenPoint: sourcePoint,
                destinationScreenPoint: destinationPoint,
                beforeFrameSequence: beforeFrame.sequence,
                beforeFrameFingerprint: beforeFrame.contentFingerprint,
                beforeBoardStateHash: binding.recognizedBoardStateHash,
                calibratedWindowFrame: calibration.windowFrame,
                calibratedImageSize: calibration.imageSize,
                dispatchedAtUptime: ProcessInfo.processInfo.systemUptime,
                minimumVerificationFrameSequence: beforeFrame.sequence &+ 1
            )
            pendingReceipt = receipt
            state = .awaitingVerification(actionID)
            return receipt
        } catch {
            if case .executing(actionID) = state {
                state = .paused(Self.pauseReason(for: error))
            }
            throw error
        }
    }

    /// One-shot verification. Call it only after the recognizer reports a new
    /// stable arbitrary-position state. Failure pauses automation and never
    /// retries the GUI action.
    func verify(
        _ receipt: ClickExecutionReceipt,
        afterBoardStateHash: String,
        minimumStableFrames: Int = 2,
        capture: WindowCaptureService
    ) async throws -> ClickVerification {
        guard pendingReceipt?.actionID == receipt.actionID,
              case .awaitingVerification(receipt.actionID) = state else {
            throw ClickExecutorError.noMatchingPendingReceipt
        }
        let verificationEpoch = safetyEpoch

        do {
            let frame = try await capture.latestFrame()
            guard safetyEpoch == verificationEpoch,
                  pendingReceipt?.actionID == receipt.actionID,
                  case .awaitingVerification(receipt.actionID) = state else {
                throw ClickExecutorError.interrupted
            }
            guard frame.target.ownerPID == receipt.ownerPID,
                  frame.target.windowID == receipt.windowID else {
                throw ClickExecutorError.targetMismatch
            }
            guard let liveGeometry = frame.liveWindowGeometry else {
                throw ClickExecutorError.targetWindowMissing
            }
            guard liveGeometry.ownerPID == receipt.ownerPID,
                  liveGeometry.windowID == receipt.windowID,
                  liveGeometry.isOnScreen,
                  liveGeometry.layer == 0 else {
                throw ClickExecutorError.targetMismatch
            }
            guard Self.rectanglesMatch(receipt.calibratedWindowFrame, liveGeometry.frame),
                  abs(receipt.calibratedImageSize.width - frame.imageSize.width) <= 1,
                  abs(receipt.calibratedImageSize.height - frame.imageSize.height) <= 1 else {
                throw ClickExecutorError.windowGeometryChanged
            }
            guard frame.sequence >= receipt.minimumVerificationFrameSequence else {
                throw ClickExecutorError.verificationFrameMissing
            }
            guard frame.consecutiveStableFrames >= max(1, minimumStableFrames) else {
                throw ClickExecutorError.verificationFrameUnstable
            }
            guard frame.contentFingerprint != receipt.beforeFrameFingerprint else {
                throw ClickExecutorError.verificationSawNoVisualChange
            }
            guard !afterBoardStateHash.isEmpty,
                  afterBoardStateHash != receipt.beforeBoardStateHash else {
                throw ClickExecutorError.verificationBoardStateUnchanged
            }

            let verification = ClickVerification(
                actionID: receipt.actionID,
                beforeFrameSequence: receipt.beforeFrameSequence,
                afterFrameSequence: frame.sequence,
                afterFrameFingerprint: frame.contentFingerprint,
                afterBoardStateHash: afterBoardStateHash,
                verifiedAtUptime: ProcessInfo.processInfo.systemUptime
            )
            pendingReceipt = nil
            state = .armed
            return verification
        } catch {
            // Manual takeover or an explicit pause wins over a late verifier.
            if safetyEpoch == verificationEpoch,
               pendingReceipt?.actionID == receipt.actionID {
                pendingReceipt = nil
                safetyEpoch &+= 1
                state = .paused(.verificationFailed(error.localizedDescription))
            }
            throw error
        }
    }

    private func validateBeforeClick(
        frame: CapturedFrame,
        binding: ClickActionBinding,
        calibration: BoardCalibration
    ) async throws {
        guard MacPermissionsService.screenRecordingStatus == .granted else {
            throw ClickExecutorError.screenRecordingPermissionMissing
        }
        guard MacPermissionsService.accessibilityStatus == .granted else {
            throw ClickExecutorError.accessibilityPermissionMissing
        }
        guard !binding.recognizedBoardStateHash.isEmpty else {
            throw ClickExecutorError.emptyBoardStateHash
        }
        guard frame.target.ownerPID == binding.ownerPID,
              frame.target.windowID == binding.windowID else {
            throw ClickExecutorError.targetMismatch
        }
        guard binding.geometryHash == calibration.geometryHash else {
            throw ClickExecutorError.geometryHashMismatch
        }
        guard frame.sequence >= binding.frameSequence else {
            throw ClickExecutorError.frameOlderThanBinding
        }
        guard frame.sequence - binding.frameSequence <= binding.maximumFrameAdvance else {
            throw ClickExecutorError.frameAdvancedTooFar
        }
        guard frame.contentFingerprint == binding.frameContentFingerprint else {
            throw ClickExecutorError.frameContentChanged
        }
        guard frame.contentFingerprint != 0 else {
            throw ClickExecutorError.frameFingerprintUnavailable
        }
        guard frame.consecutiveStableFrames >= binding.minimumStableFrames else {
            throw ClickExecutorError.frameNotStable
        }
        guard abs(frame.imageSize.width - calibration.imageSize.width) <= 1,
              abs(frame.imageSize.height - calibration.imageSize.height) <= 1 else {
            throw ClickExecutorError.imageGeometryChanged
        }
        try await validateWindowAuthority(
            liveGeometry: frame.liveWindowGeometry,
            ownerPID: binding.ownerPID,
            windowID: binding.windowID,
            calibration: calibration
        )
    }

    private func validateLiveTarget(
        capture: WindowCaptureService,
        binding: ClickActionBinding,
        calibration: BoardCalibration,
        actionID: UUID,
        epoch: UInt64
    ) async throws {
        guard MacPermissionsService.accessibilityStatus == .granted else {
            throw ClickExecutorError.accessibilityPermissionMissing
        }
        guard MacPermissionsService.screenRecordingStatus == .granted else {
            throw ClickExecutorError.screenRecordingPermissionMissing
        }
        let geometry = await capture.currentLiveWindowGeometry()
        try ensureStillExecuting(actionID: actionID, epoch: epoch)
        try await validateWindowAuthority(
            liveGeometry: geometry,
            ownerPID: binding.ownerPID,
            windowID: binding.windowID,
            calibration: calibration
        )
    }

    private func validateWindowAuthority(
        liveGeometry: LiveWindowGeometry?,
        ownerPID: pid_t,
        windowID: CGWindowID,
        calibration: BoardCalibration
    ) async throws {
        guard let liveGeometry else { throw ClickExecutorError.targetWindowMissing }
        guard liveGeometry.ownerPID == ownerPID,
              liveGeometry.windowID == windowID else {
            throw ClickExecutorError.targetMismatch
        }
        guard liveGeometry.isOnScreen else { throw ClickExecutorError.targetNotOnScreen }
        guard liveGeometry.layer == 0 else {
            throw ClickExecutorError.unexpectedWindowLayer(liveGeometry.layer)
        }
        guard calibration.matches(windowFrame: liveGeometry.frame) else {
            throw ClickExecutorError.windowGeometryChanged
        }

        let frontmostPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        guard frontmostPID == ownerPID else { throw ClickExecutorError.targetNotFrontmost }
    }

    private func validatePoints(
        _ source: CGPoint,
        _ destination: CGPoint,
        liveWindowFrame: CGRect?,
        calibration: BoardCalibration,
        windowID: CGWindowID
    ) throws {
        guard let liveWindowFrame,
              calibration.matches(windowFrame: liveWindowFrame),
              liveWindowFrame.insetBy(dx: -1, dy: -1).contains(source),
              liveWindowFrame.insetBy(dx: -1, dy: -1).contains(destination) else {
            throw ClickExecutorError.roiViolation
        }
        guard Self.targetWindowIsTopmost(windowID, at: [source, destination]) else {
            throw ClickExecutorError.targetWindowOccluded
        }
    }

    private func postClick(at point: CGPoint, actionID: UUID, epoch: UInt64) async throws {
        try ensureStillExecuting(actionID: actionID, epoch: epoch)
        guard MacPermissionsService.accessibilityStatus == .granted else {
            throw ClickExecutorError.accessibilityPermissionMissing
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            throw ClickExecutorError.eventCreationFailed
        }

        let eventSignature = Int64(bitPattern: 0x5849_414e_4751_4950)
        mouseDown.setIntegerValueField(.eventSourceUserData, value: eventSignature)
        mouseUp.setIntegerValueField(.eventSourceUserData, value: eventSignature)

        mouseDown.post(tap: .cghidEventTap)
        do {
            try await Task.sleep(nanoseconds: mouseDownDurationNanoseconds)
        } catch {
            // Always release the button, even when cancellation/manual takeover
            // arrives while it is down.
            mouseUp.post(tap: .cghidEventTap)
            throw error
        }
        mouseUp.post(tap: .cghidEventTap)
        try ensureStillExecuting(actionID: actionID, epoch: epoch)
    }

    private func ensureStillExecuting(actionID: UUID, epoch: UInt64) throws {
        guard safetyEpoch == epoch,
              case .executing(actionID) = state else {
            throw ClickExecutorError.interrupted
        }
    }

    private static func pauseReason(for error: Error) -> AutomationPauseReason {
        guard let error = error as? ClickExecutorError else {
            return .inputFailure(error.localizedDescription)
        }
        switch error {
        case .accessibilityPermissionMissing: return .accessibilityPermissionMissing
        case .screenRecordingPermissionMissing: return .screenRecordingPermissionMissing
        case .targetWindowMissing, .targetNotOnScreen: return .targetWindowMissing
        case .targetNotFrontmost: return .targetNotFrontmost
        case .targetMismatch, .unexpectedWindowLayer, .targetWindowOccluded: return .targetWindowChanged
        case .geometryHashMismatch, .windowGeometryChanged, .imageGeometryChanged: return .geometryChanged
        case .frameNotStable: return .frameUnstable
        case .frameOlderThanBinding, .frameAdvancedTooFar: return .staleFrame
        case .frameContentChanged: return .boardStateChanged
        case .frameFingerprintUnavailable: return .captureFailure(error.localizedDescription)
        case .roiViolation: return .roiViolation
        default: return .inputFailure(error.localizedDescription)
        }
    }

    private static func rectanglesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// CoreGraphics returns windows in front-to-back order. Reject a click when
    /// any visible window in front of the locked target covers an action point,
    /// even if that window belongs to the same foreground application.
    private static func targetWindowIsTopmost(_ windowID: CGWindowID, at points: [CGPoint]) -> Bool {
        guard !points.isEmpty,
              let rawList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ),
              let windows = rawList as? [[String: Any]] else {
            return false
        }

        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
            if CGWindowID(number.uint32Value) == windowID { return true }

            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else {
                continue
            }
            if points.contains(where: bounds.contains) { return false }
        }
        return false
    }
}
