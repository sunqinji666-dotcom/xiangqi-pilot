import AppKit
import ApplicationServices
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

enum TargetActivationRoute: Sendable, Equatable {
    case alreadyFrontmost
    case cooperative
    case direct
}

/// Immutable precondition token created from the exact stable frame used by the
/// recognizer/engine. A newer frame may still be accepted only when its cheap
/// visual fingerprint is unchanged and it is within `maximumFrameAdvance`.
struct ClickActionBinding: Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let frameSequence: UInt64
    let frameContentFingerprint: UInt64
    let boardVisualSignature: BoardFrameSignature
    let boardGeometry: RecognitionBoardGeometry
    let recognizedBoardStateHash: String
    let geometryHash: String
    let minimumStableFrames: Int
    let maximumFrameAdvance: UInt64

    init(
        ownerPID: pid_t,
        windowID: CGWindowID,
        frameSequence: UInt64,
        frameContentFingerprint: UInt64,
        boardVisualSignature: BoardFrameSignature,
        boardGeometry: RecognitionBoardGeometry,
        recognizedBoardStateHash: String,
        geometryHash: String,
        minimumStableFrames: Int = 2,
        maximumFrameAdvance: UInt64 = 90
    ) {
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.frameSequence = frameSequence
        self.frameContentFingerprint = frameContentFingerprint
        self.boardVisualSignature = boardVisualSignature
        self.boardGeometry = boardGeometry
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

    private let boardDifferencer = BoardFrameDifferencer()
    private var safetyEpoch: UInt64 = 0
    private let mouseDownDurationNanoseconds: UInt64
    private let sourceToDestinationDelayNanoseconds: UInt64

    init(mouseDownMilliseconds: UInt64 = 18, sourceToDestinationDelayMilliseconds: UInt64 = 120) {
        mouseDownDurationNanoseconds = mouseDownMilliseconds * 1_000_000
        sourceToDestinationDelayNanoseconds = sourceToDestinationDelayMilliseconds * 1_000_000
    }

    func arm() throws {
        guard pendingReceipt == nil else { throw ClickExecutorError.anotherActionInFlight }
        switch state {
        case .armed:
            // Arming is idempotent. A duplicate confirmation must not advance
            // the epoch and invalidate a preflight that already owns it.
            return
        case .executing, .awaitingVerification:
            throw ClickExecutorError.anotherActionInFlight
        case .paused, .manualTakeover:
            break
        }
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

    /// Hands foreground ownership to the already-locked target application and
    /// returns a fresh stable frame from that exact window. No input event is
    /// posted here. The caller must build its action binding from the returned
    /// frame so activation/Space animations can never make an old token valid.
    func prepareTargetForInput(
        ownerPID: pid_t,
        windowID: CGWindowID,
        calibration: BoardCalibration,
        capture: WindowCaptureService,
        timeout: Duration = .seconds(2)
    ) async throws -> CapturedFrame {
        guard case .armed = state else {
            if pendingReceipt != nil { throw ClickExecutorError.anotherActionInFlight }
            throw ClickExecutorError.notArmed
        }
        guard pendingReceipt == nil else { throw ClickExecutorError.anotherActionInFlight }
        guard MacPermissionsService.screenRecordingStatus == .granted else {
            throw ClickExecutorError.screenRecordingPermissionMissing
        }
        guard MacPermissionsService.accessibilityStatus == .granted else {
            throw ClickExecutorError.accessibilityPermissionMissing
        }

        let epoch = safetyEpoch
        let activationContext = await MainActor.run { () -> (NSRunningApplication, TargetActivationRoute)? in
            guard let application = NSRunningApplication(processIdentifier: ownerPID) else {
                return nil
            }
            let route = Self.activationRoute(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                currentPID: NSRunningApplication.current.processIdentifier,
                targetPID: ownerPID
            )
            return (application, route)
        }
        guard let activationContext else { throw ClickExecutorError.targetWindowMissing }

        // Resolve the exact locked window's current frame before attempting
        // activation. The user may have moved it since calibration.
        guard let initialLiveGeometry = await capture.currentLiveWindowGeometry(),
              initialLiveGeometry.ownerPID == ownerPID,
              initialLiveGeometry.windowID == windowID else {
            throw ClickExecutorError.targetWindowMissing
        }
        guard calibration.matchesSize(windowFrame: initialLiveGeometry.frame) else {
            throw ClickExecutorError.windowGeometryChanged
        }
        var currentTargetFrame = initialLiveGeometry.frame

        let activationRequest: Bool
        switch activationContext.1 {
            case .alreadyFrontmost:
                activationRequest = true
            case .cooperative:
                await MainActor.run {
                    NSApp.yieldActivation(to: activationContext.0)
                }
                activationRequest = await Self.activateThroughWorkspace(activationContext.0)
            case .direct:
                // Accessibility clients may legitimately invoke Confirm while
                // another app is frontmost. NSRunningApplication.activate can
                // report success while macOS keeps the previous foreground app.
                // Reopening the already-running bundle with an activating
                // NSWorkspace configuration reliably performs the public,
                // user-visible foreground handoff without launching a duplicate.
                activationRequest = await Self.activateThroughWorkspace(activationContext.0)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // A successful NSRunningApplication result means only that macOS
        // accepted the request; it does not prove that foreground ownership
        // changed. Give a cooperative/direct request a short opportunity to
        // settle, then use the already-authorized Accessibility path once.
        let fallbackDelay: Duration = activationRequest ? .milliseconds(180) : .zero
        let fallbackNotBefore = clock.now.advanced(by: fallbackDelay)
        let titleBarFallbackNotBefore = fallbackNotBefore.advanced(by: .milliseconds(260))
        var attemptedAccessibilityFallback = false
        var attemptedTitleBarFallback = false
        var sawOnScreenTarget = false
        var sawFrontmostTarget = false
        var previousBoardSignature: BoardFrameSignature?
        var boardStableSince: ContinuousClock.Instant?
        while clock.now < deadline {
            guard safetyEpoch == epoch,
                  case .armed = state,
                  pendingReceipt == nil else {
                throw ClickExecutorError.interrupted
            }

            let frontmostPID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            if frontmostPID != ownerPID,
               !attemptedAccessibilityFallback,
               clock.now >= fallbackNotBefore {
                attemptedAccessibilityFallback = true
                let expectedFrame = currentTargetFrame
                _ = await MainActor.run {
                    Self.raiseMatchingTargetWindowWithAccessibility(
                        ownerPID: ownerPID,
                        expectedFrame: expectedFrame
                    )
                }
            }

            if frontmostPID != ownerPID,
               attemptedAccessibilityFallback,
               !attemptedTitleBarFallback,
               clock.now >= titleBarFallbackNotBefore {
                attemptedTitleBarFallback = true
                let activationPoint = CGPoint(
                    x: currentTargetFrame.midX,
                    y: currentTargetFrame.minY + 15
                )
                if Self.targetWindowIsTopmost(
                    windowID,
                    ownerPID: ownerPID,
                    expectedFrame: currentTargetFrame,
                    at: [activationPoint]
                ) {
                    try await postActivationClick(at: activationPoint, epoch: epoch)
                }
            }

            if let frame = try? await capture.latestFrame(),
               frame.target.ownerPID == ownerPID,
               frame.target.windowID == windowID,
               let liveGeometry = frame.liveWindowGeometry,
               liveGeometry.ownerPID == ownerPID,
               liveGeometry.windowID == windowID {
                currentTargetFrame = liveGeometry.frame
                sawOnScreenTarget = sawOnScreenTarget || liveGeometry.isOnScreen
                if liveGeometry.isOnScreen,
                   liveGeometry.layer == 0,
                   frontmostPID == ownerPID,
                   calibration.matchesSize(windowFrame: liveGeometry.frame),
                   abs(frame.imageSize.width - calibration.imageSize.width) <= 1,
                   abs(frame.imageSize.height - calibration.imageSize.height) <= 1,
                   frame.contentFingerprint != 0 {
                    sawFrontmostTarget = true
                    let signature = boardDifferencer.signature(
                        image: frame.image,
                        frameSequence: frame.sequence,
                        geometry: Self.recognitionGeometry(from: calibration)
                    )
                    if let previousBoardSignature {
                        let boardChanged = !boardDifferencer.changes(
                            from: previousBoardSignature,
                            to: signature,
                            minimumScore: 0.035
                        ).cells.isEmpty
                        if boardChanged {
                            boardStableSince = clock.now
                        } else {
                            boardStableSince = boardStableSince ?? clock.now
                            if let boardStableSince,
                               boardStableSince.duration(to: clock.now) >= .milliseconds(120) {
                                return frame
                            }
                        }
                    } else {
                        boardStableSince = clock.now
                    }
                    previousBoardSignature = signature
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }

        if !sawOnScreenTarget { throw ClickExecutorError.targetNotOnScreen }
        if sawFrontmostTarget { throw ClickExecutorError.frameNotStable }
        throw ClickExecutorError.targetNotFrontmost
    }

    static func activationRoute(
        frontmostPID: pid_t?,
        currentPID: pid_t,
        targetPID: pid_t
    ) -> TargetActivationRoute {
        if frontmostPID == targetPID { return .alreadyFrontmost }
        if frontmostPID == currentPID { return .cooperative }
        return .direct
    }

    @MainActor
    private static func activateThroughWorkspace(_ application: NSRunningApplication) async -> Bool {
        // For an already-running target, ask AppKit for the normal direct
        // foreground handoff first.  Re-opening its bundle alone can report a
        // successful launch while leaving the cockpit frontmost.
        _ = application.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(80))
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return true
        }
        guard let bundleURL = application.bundleURL else {
            return application.activate(options: [.activateAllWindows])
        }
        let expectedPID = application.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            ) { activatedApplication, error in
                continuation.resume(
                    returning: error == nil
                        && activatedApplication?.processIdentifier == expectedPID
                )
            }
        }
    }

    /// Returns a match only when one and only one AX window has the complete
    /// calibrated position and size. Ambiguity is a hard failure: fallback
    /// activation must never guess between same-process windows.
    static func uniqueMatchingAXWindowIndex(
        frames: [CGRect],
        expectedFrame: CGRect,
        tolerance: CGFloat = 0
    ) -> Int? {
        let matchingIndices = frames.indices.filter { index in
            rectanglesMatch(frames[index], expectedFrame, tolerance: tolerance)
        }
        guard matchingIndices.count == 1 else { return nil }
        return matchingIndices[0]
    }

    @MainActor
    private static func raiseMatchingTargetWindowWithAccessibility(
        ownerPID: pid_t,
        expectedFrame: CGRect
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(ownerPID)
        var actualApplicationPID: pid_t = 0
        guard AXUIElementGetPid(applicationElement, &actualApplicationPID) == .success,
              actualApplicationPID == ownerPID,
              let windows = axWindows(of: applicationElement) else {
            return false
        }

        let framedWindows = windows.compactMap { window -> (AXUIElement, CGRect)? in
            guard let frame = axWindowFrame(window) else { return nil }
            return (window, frame)
        }
        guard let matchingIndex = uniqueMatchingAXWindowIndex(
            frames: framedWindows.map { $0.1 },
            expectedFrame: expectedFrame
        ) else {
            return false
        }

        let targetWindow = framedWindows[matchingIndex].0
        var actualWindowPID: pid_t = 0
        guard AXUIElementGetPid(targetWindow, &actualWindowPID) == .success,
              actualWindowPID == ownerPID,
              setAXBooleanIfWritable(targetWindow, attribute: kAXMainAttribute, value: true),
              setRequiredAXBoolean(
                applicationElement,
                attribute: kAXFrontmostAttribute,
                value: true
              ),
              AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success,
              setAXBooleanIfWritable(targetWindow, attribute: kAXFocusedAttribute, value: true) else {
            return false
        }
        return true
    }

    private static func axWindows(of application: AXUIElement) -> [AXUIElement]? {
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success else {
            return nil
        }
        return rawWindows as? [AXUIElement]
    }

    private static func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        guard let position = axPoint(window, attribute: kAXPositionAttribute),
              let size = axSize(window, attribute: kAXSizeAttribute),
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(rawValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Optional window attributes are written only when the target advertises
    /// them as settable. Unsupported attributes are safely skipped; a failed
    /// write to an advertised attribute aborts the fallback.
    private static func setAXBooleanIfWritable(
        _ element: AXUIElement,
        attribute: String,
        value: Bool
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        let queryResult = AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        )
        guard queryResult == .success else { return true }
        guard isSettable.boolValue else { return true }
        return AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }

    private static func setRequiredAXBoolean(
        _ element: AXUIElement,
        attribute: String,
        value: Bool
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        ) == .success,
              isSettable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
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

            guard let beforeWindowFrame = beforeFrame.liveWindowGeometry?.frame else {
                throw ClickExecutorError.targetWindowMissing
            }
            let sourcePoint = try calibration.globalScreenPoint(for: move.source, in: beforeWindowFrame)
            var destinationPoint = try calibration.globalScreenPoint(for: move.destination, in: beforeWindowFrame)
            try validatePoints(
                sourcePoint,
                destinationPoint,
                liveWindowFrame: beforeFrame.liveWindowGeometry?.frame,
                calibration: calibration,
                ownerPID: binding.ownerPID,
                windowID: binding.windowID
            )

            try await postClick(at: sourcePoint, actionID: actionID, epoch: epoch)
            try await Task.sleep(nanoseconds: sourceToDestinationDelayNanoseconds)
            try ensureStillExecuting(actionID: actionID, epoch: epoch)

            // Re-check authority and geometry between the source selection and
            // destination click. A pause at this point leaves only a selected
            // piece; it does not send an unintended move.
            let destinationGeometry = try await validateLiveTarget(
                capture: capture,
                binding: binding,
                calibration: calibration,
                actionID: actionID,
                epoch: epoch
            )
            // Follow a pure window translation that happened after selecting
            // the piece. The destination is always derived from the latest
            // frame of the same locked windowID.
            destinationPoint = try calibration.globalScreenPoint(
                for: move.destination,
                in: destinationGeometry.frame
            )
            guard Self.targetWindowIsTopmost(
                binding.windowID,
                ownerPID: binding.ownerPID,
                expectedFrame: destinationGeometry.frame,
                at: [destinationPoint]
            ) else {
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
                calibratedWindowFrame: destinationGeometry.frame,
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
            guard abs(receipt.calibratedWindowFrame.width - liveGeometry.frame.width) <= 0.5,
                  abs(receipt.calibratedWindowFrame.height - liveGeometry.frame.height) <= 0.5,
                  abs(receipt.calibratedImageSize.width - frame.imageSize.width) <= 1,
                  abs(receipt.calibratedImageSize.height - frame.imageSize.height) <= 1 else {
                throw ClickExecutorError.windowGeometryChanged
            }
            guard frame.sequence >= receipt.minimumVerificationFrameSequence else {
                throw ClickExecutorError.verificationFrameMissing
            }
            _ = minimumStableFrames
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
        if frame.contentFingerprint != binding.frameContentFingerprint {
            let currentBoardSignature = boardDifferencer.signature(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: binding.boardGeometry
            )
            let boardChange = boardDifferencer.changes(
                from: binding.boardVisualSignature,
                to: currentBoardSignature,
                minimumScore: 0.035
            )
            guard boardChange.cells.isEmpty else {
                throw ClickExecutorError.frameContentChanged
            }
        }
        guard frame.contentFingerprint != 0 else {
            throw ClickExecutorError.frameFingerprintUnavailable
        }
        if frame.consecutiveStableFrames < binding.minimumStableFrames {
            let currentBoardSignature = boardDifferencer.signature(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: binding.boardGeometry
            )
            let boardChange = boardDifferencer.changes(
                from: binding.boardVisualSignature,
                to: currentBoardSignature,
                minimumScore: 0.035
            )
            guard boardChange.cells.isEmpty else {
                throw ClickExecutorError.frameNotStable
            }
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
    ) async throws -> LiveWindowGeometry {
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
        guard let geometry else { throw ClickExecutorError.targetWindowMissing }
        return geometry
    }

    private static func recognitionGeometry(from calibration: BoardCalibration) -> RecognitionBoardGeometry {
        let width = calibration.imageSize.width
        let height = calibration.imageSize.height
        func visionPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / width, y: 1 - point.y / height)
        }
        return RecognitionBoardGeometry(
            topLeft: visionPoint(calibration.corners.topLeft),
            topRight: visionPoint(calibration.corners.topRight),
            bottomRight: visionPoint(calibration.corners.bottomRight),
            bottomLeft: visionPoint(calibration.corners.bottomLeft)
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
        guard calibration.matchesSize(windowFrame: liveGeometry.frame) else {
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
        ownerPID: pid_t,
        windowID: CGWindowID
    ) throws {
        guard let liveWindowFrame,
              calibration.matchesSize(windowFrame: liveWindowFrame),
              liveWindowFrame.insetBy(dx: -1, dy: -1).contains(source),
              liveWindowFrame.insetBy(dx: -1, dy: -1).contains(destination) else {
            throw ClickExecutorError.roiViolation
        }
        guard Self.targetWindowIsTopmost(
            windowID,
            ownerPID: ownerPID,
            expectedFrame: liveWindowFrame,
            at: [source, destination]
        ) else {
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

    /// Activates an already verified, unobscured target by clicking only its
    /// title bar. This is a fallback for macOS 14+ where public activation APIs
    /// may not cross displays/Spaces. It never touches the board ROI.
    private func postActivationClick(at point: CGPoint, epoch: UInt64) async throws {
        guard safetyEpoch == epoch,
              case .armed = state,
              pendingReceipt == nil else {
            throw ClickExecutorError.interrupted
        }
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
        mouseDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: mouseDownDurationNanoseconds)
        mouseUp.post(tap: .cghidEventTap)
        guard safetyEpoch == epoch,
              case .armed = state,
              pendingReceipt == nil else {
            throw ClickExecutorError.interrupted
        }
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

    /// CoreGraphics returns windows in front-to-back order. Some applications
    /// (including visual effect/cursor helpers) publish mouse-transparent
    /// composition surfaces above ordinary windows. Those surfaces must not be
    /// treated as click blockers when Accessibility hit-testing still resolves
    /// the exact locked target window at every action point.
    private static func targetWindowIsTopmost(
        _ windowID: CGWindowID,
        ownerPID: pid_t,
        expectedFrame: CGRect,
        at points: [CGPoint]
    ) -> Bool {
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
            if points.contains(where: bounds.contains) {
                return points.allSatisfy {
                    accessibilityHitMatchesTargetWindow(
                        at: $0,
                        ownerPID: ownerPID,
                        expectedFrame: expectedFrame
                    )
                }
            }
        }
        return false
    }

    private static func accessibilityHitMatchesTargetWindow(
        at point: CGPoint,
        ownerPID: pid_t,
        expectedFrame: CGRect
    ) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
              let hitElement else {
            return false
        }

        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hitElement, &hitPID) == .success,
              hitPID == ownerPID else {
            return false
        }

        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            hitElement,
            kAXWindowAttribute as CFString,
            &rawWindow
        ) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              let frame = axWindowFrame(rawWindow as! AXUIElement) else {
            return false
        }
        return rectanglesMatch(frame, expectedFrame)
    }
}
