import AppKit
import CoreGraphics
import Foundation
import Vision

enum GridTargetBootstrapError: LocalizedError {
    case unsupportedTarget
    case permissionMissing
    case targetMissing
    case activationFailed
    case eventCreationFailed
    case noVisualResponse
    case concedeUnavailable
    case paidConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget: "当前窗口不是已支持的本机交点棋应用"
        case .permissionMissing: "缺少屏幕录制或辅助功能权限"
        case .targetMissing: "目标窗口已消失"
        case .activationFailed: "无法激活目标窗口"
        case .eventCreationFailed: "无法创建启动对局点击"
        case .noVisualResponse: "启动入口未产生画面变化，请在驾驶舱内检查目标应用状态"
        case .concedeUnavailable: "锁定窗口中未找到可确认的“认输”控件"
        case .paidConfirmationRequired: "腾讯围棋提示需确认消耗金币；驾驶舱已停止，不会替你确认"
        }
    }
}

/// Pure, conservative classification for Tencent Go's account-affecting
/// dialog.  It deliberately relies only on dialog wording, never a fallback
/// coordinate, so callers can abort before issuing any further client input.
enum TencentGoModalClassifier {
    static func requiresPaidConfirmation(ocrTexts: [String]) -> Bool {
        let text = ocrTexts
            .joined(separator: " ")
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isNewline }
        return text.contains("免费对局")
            || (text.contains("消耗") && (text.contains("金币") || text.contains("确定开始")))
    }
}

/// Very narrow bootstrapper for the two local clients placed in scope by the
/// user.  It never chooses board intersections.  It can only press their
/// public home-screen AI/practice entry point after confirming the locked
/// bundle identifier, then waits for a visible response before calibration.
actor GridTargetBootstrapper {
    /// Ends only the already locked Tencent Go game through its public
    /// “认输 → 确认” controls. This is separate from board-move execution
    /// and is reached only by the cockpit's explicit confirmation.
    func concedeCurrentGo(capture: WindowCaptureService) async throws {
        guard MacPermissionsService.screenRecordingStatus == .granted,
              MacPermissionsService.accessibilityStatus == .granted else {
            throw GridTargetBootstrapError.permissionMissing
        }
        guard let target = await capture.lockedTarget(),
              target.bundleIdentifier == "com.tencent.TtgoForIos",
              let frame = try? await capture.latestFrame(),
              let windowFrame = frame.liveWindowGeometry?.frame,
              let app = NSRunningApplication(processIdentifier: target.ownerPID) else {
            throw GridTargetBootstrapError.unsupportedTarget
        }
        guard await GridClickExecutor.activateLockedTarget(
            application: app,
            ownerPID: target.ownerPID,
            expectedFrame: windowFrame
        ) else {
            throw GridTargetBootstrapError.activationFailed
        }
        try await Task.sleep(for: .milliseconds(120))
        // Tencent's compact bottom-toolbar text is occasionally omitted by
        // Vision at this window scale. This fallback is still safe here: the
        // action is behind the cockpit's destructive confirmation, the target
        // bundle/window have just been verified, and this is the same public
        // resign control used by the documented fresh-game bootstrap path.
        let labels = try await currentLabels(capture)
        try await postClick(label: labels.best("认输"), fallback: CGPoint(x: 0.87, y: 0.87), in: windowFrame)
        let confirmation = try await waitForLabels(capture, timeout: .seconds(2)) {
            $0.contains("确定") || $0.contains("确认")
        }
        let beforeConfirmation = try await capture.latestFrame()
        try await postClick(
            label: confirmation.best("确定") ?? confirmation.best("确认"),
            fallback: CGPoint(x: 0.58, y: 0.595),
            in: windowFrame
        )
        // The result glyph can be decorative artwork and therefore absent
        // from OCR. Prove the confirmed public action by waiting for the
        // locked client window to repaint after the confirmation click.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if let after = try? await capture.latestFrame(),
               after.sequence > beforeConfirmation.sequence,
               after.contentFingerprint != beforeConfirmation.contentFingerprint {
                return
            }
            try await Task.sleep(for: .milliseconds(45))
        }
        throw GridTargetBootstrapError.noVisualResponse
    }

    func advanceLocalAI(
        game: GameKind,
        stage: Int,
        capture: WindowCaptureService,
        authorizingTencentPaidMatch: Bool = false
    ) async throws {
        guard MacPermissionsService.screenRecordingStatus == .granted,
              MacPermissionsService.accessibilityStatus == .granted else {
            throw GridTargetBootstrapError.permissionMissing
        }
        guard let target = await capture.lockedTarget(),
              let frame = try? await capture.latestFrame(),
              let windowFrame = frame.liveWindowGeometry?.frame,
              let app = NSRunningApplication(processIdentifier: target.ownerPID) else {
            throw GridTargetBootstrapError.targetMissing
        }
        let expectedBundle: String
        let normalizedPoints: [CGPoint]
        switch game {
        case .gomoku:
            expectedBundle = "com.sining.wuziqi"
            // Stage 0 opens 人机对战; stage 1 picks 初出茅庐 (the lowest
            // visible AI level) on the following card list.
            normalizedPoints = [stage == 0
                ? CGPoint(x: 0.50, y: 0.64)
                : CGPoint(x: 0.50, y: 0.28)]
        case .go:
            expectedBundle = "com.tencent.TtgoForIos"
            // 腾讯围棋：阶段 0 依次经过首页“AI训练”、AI训练弹窗
            // “AI对局”、对局设置页“开始对局”。后续重入设置页只
            // 点击最后一步；每一步都绑定锁定窗口的画面回执。
            normalizedPoints = stage == 0
                ? [
                    CGPoint(x: 0.72, y: 0.90),
                    CGPoint(x: 0.44, y: 0.58),
                    CGPoint(x: 0.50, y: 0.82)
                ]
                : [CGPoint(x: 0.50, y: 0.82)]
        case .xiangqi:
            throw GridTargetBootstrapError.unsupportedTarget
        }
        guard target.bundleIdentifier == expectedBundle else {
            throw GridTargetBootstrapError.unsupportedTarget
        }
        let activated = await GridClickExecutor.activateLockedTarget(
            application: app,
            ownerPID: target.ownerPID,
            expectedFrame: windowFrame
        )
        guard activated else { throw GridTargetBootstrapError.activationFailed }
        try await Task.sleep(for: .milliseconds(150))
        var baseline = frame

        // Tencent Go is a stateful Unity wrapper: returning to its home page
        // does not necessarily discard a resumable game.  A generic pixel
        // fingerprint is therefore not a safe page-transition signal (the
        // home-room list animates continuously).  Its public controls are
        // text-labelled, so use local OCR on the already locked capture to
        // prove each page before moving to the next public control.
        if game == .go, stage == 0 {
            try await launchTencentGoAI(
                capture: capture,
                windowFrame: windowFrame,
                authorizingTencentPaidMatch: authorizingTencentPaidMatch
            )
            return
        }

        if game == .gomoku, stage == 0 {
            // The local Gomoku client keeps an in-progress board alive when
            // relaunched. Its compact back control sits below the macOS title
            // bar (about 13% across and 8.5% down in the captured window);
            // return to the landing page before pressing the cockpit's
            // documented 人机对战 entry point.
            let back = CGPoint(
                x: windowFrame.minX + 0.13 * windowFrame.width,
                y: windowFrame.minY + 0.085 * windowFrame.height
            )
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: back, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: back, mouseButton: .left) else {
                throw GridTargetBootstrapError.eventCreationFailed
            }
            down.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
            up.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(300))
            if let refreshed = try? await capture.latestFrame() { baseline = refreshed }
        }

        for (index, normalizedPoint) in normalizedPoints.enumerated() {
            let point = CGPoint(
                x: windowFrame.minX + normalizedPoint.x * windowFrame.width,
                y: windowFrame.minY + normalizedPoint.y * windowFrame.height
            )
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw GridTargetBootstrapError.eventCreationFailed
            }
            down.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
            up.post(tap: .cghidEventTap)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                if let after = try? await capture.latestFrame(),
                   after.sequence > baseline.sequence,
                   after.contentFingerprint != baseline.contentFingerprint {
                    // 腾讯围棋首页的房间列表会自行刷新；阶段 0 必须
                    // 完整走完“AI训练 → AI对局”两步，不能把背景刷新
                    // 误判为已经进入对局。
                    if game == .go, stage == 0, index + 1 < normalizedPoints.count {
                        baseline = after
                        break
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if let next = try? await capture.latestFrame() { baseline = next }
        }
        throw GridTargetBootstrapError.noVisualResponse
    }

    /// Drives only Tencent Go's public, non-board controls. The caller has
    /// already proved that the target is the locked Tencent Go window.
    private func launchTencentGoAI(
        capture: WindowCaptureService,
        windowFrame: CGRect,
        authorizingTencentPaidMatch: Bool
    ) async throws {
        var labels = try await currentLabels(capture)
        try await resolveTencentPaidConfirmationIfAuthorized(
            labels: &labels,
            capture: capture,
            windowFrame: windowFrame,
            authorizingTencentPaidMatch: authorizingTencentPaidMatch
        )

        // A completed Tencent game keeps its result card above the home
        // control. Dismiss that public “对局结束” card first so a prior loss
        // or win cannot block the cockpit from starting the next AI match.
        if await isTencentResultCardVisible(labels: labels, capture: capture) {
            // Do not press the card's “确定／继续” actions: their meaning
            // varies between client versions.  The identified close affordance
            // is stable, outside the board, and preserves the home flow.
            // More importantly, never continue until the card has actually
            // disappeared; otherwise the subsequent home clicks only land on
            // the modal and the cockpit falsely reports a newly opened game.
            for _ in 0..<2 {
                try await postClick(normalized: CGPoint(x: 0.65, y: 0.17), in: windowFrame)
                try await Task.sleep(for: .milliseconds(300))
                labels = try await currentLabels(capture)
                if !(await isTencentResultCardVisible(labels: labels, capture: capture)) {
                    break
                }
            }
            guard !(await isTencentResultCardVisible(labels: labels, capture: capture)) else {
                throw GridTargetBootstrapError.noVisualResponse
            }
            try await resolveTencentPaidConfirmationIfAuthorized(
                labels: &labels,
                capture: capture,
                windowFrame: windowFrame,
                authorizingTencentPaidMatch: authorizingTencentPaidMatch
            )
        }

        // Finish a restored local game first. We locate the real 认输 button
        // in the captured client instead of assuming an absolute position.
        if labels.contains("认输") {
            try await postClick(label: labels.best("认输"), fallback: CGPoint(x: 0.87, y: 0.87), in: windowFrame)
            // The Unity confirmation text is sometimes too small for macOS
            // OCR even though the modal itself is visible. This fallback is
            // deliberately limited to this immediately preceding, verified
            // public 认输 action; it maps to the modal's right “确定” button,
            // never to a board intersection.
            let confirmation = try? await waitForLabels(capture, timeout: .seconds(2)) {
                $0.contains("确定") || $0.contains("确认")
            }
            try await postClick(
                label: confirmation?.best("确定") ?? confirmation?.best("确认"),
                fallback: CGPoint(x: 0.58, y: 0.595),
                in: windowFrame
            )
            try await Task.sleep(for: .milliseconds(350))
            _ = try? await waitForLabels(capture, timeout: .seconds(2)) { !$0.contains("认输") }
            labels = try await currentLabels(capture)
            try await resolveTencentPaidConfirmationIfAuthorized(
                labels: &labels,
                capture: capture,
                windowFrame: windowFrame,
                authorizingTencentPaidMatch: authorizingTencentPaidMatch
            )
        }

        // The title-strip home control is stable and is not a board point.
        try await postClick(normalized: CGPoint(x: 0.105, y: 0.028), in: windowFrame)
        labels = await labelsAfterWaiting(capture, timeout: .seconds(3)) { labels in
            labels.contains("AI训练") && (labels.contains("约战") || labels.contains("挑战赛") || labels.contains("19路对弈"))
        }
        try await resolveTencentPaidConfirmationIfAuthorized(
            labels: &labels,
            capture: capture,
            windowFrame: windowFrame,
            authorizingTencentPaidMatch: authorizingTencentPaidMatch
        )

        // Prefer the lower home-card label. This avoids accidentally pressing
        // the inactive title tab that has the same “AI训练” text.
        try await postClick(label: labels.best("AI训练", preferLowerHalf: true), fallback: CGPoint(x: 0.72, y: 0.90), in: windowFrame)
        labels = await labelsAfterWaiting(capture, timeout: .seconds(3)) { $0.contains("AI对局") && $0.contains("你行你上") }
        try await resolveTencentPaidConfirmationIfAuthorized(
            labels: &labels,
            capture: capture,
            windowFrame: windowFrame,
            authorizingTencentPaidMatch: authorizingTencentPaidMatch
        )

        try await postClick(label: labels.best("AI对局"), fallback: CGPoint(x: 0.44, y: 0.58), in: windowFrame)
        labels = await labelsAfterWaiting(capture, timeout: .seconds(3)) { labels in
            labels.contains("开始对局") && !labels.contains("你行你上")
        }
        try await resolveTencentPaidConfirmationIfAuthorized(
            labels: &labels,
            capture: capture,
            windowFrame: windowFrame,
            authorizingTencentPaidMatch: authorizingTencentPaidMatch
        )

        try await postClick(label: labels.best("开始对局"), fallback: CGPoint(x: 0.50, y: 0.82), in: windowFrame)
        var finalLabels = await labelsAfterWaiting(capture, timeout: .seconds(5)) { labels in
            labels.contains("认输") && (labels.contains("悔棋") || labels.contains("提示"))
        }
        try await resolveTencentPaidConfirmationIfAuthorized(
            labels: &finalLabels,
            capture: capture,
            windowFrame: windowFrame,
            authorizingTencentPaidMatch: authorizingTencentPaidMatch
        )
        if !(finalLabels.contains("认输") && (finalLabels.contains("悔棋") || finalLabels.contains("提示"))) {
            finalLabels = await labelsAfterWaiting(capture, timeout: .seconds(5)) { labels in
                labels.contains("认输") && (labels.contains("悔棋") || labels.contains("提示"))
            }
        }
        guard finalLabels.contains("认输") && (finalLabels.contains("悔棋") || finalLabels.contains("提示")) else {
            throw GridTargetBootstrapError.noVisualResponse
        }
    }

    private func currentLabels(_ capture: WindowCaptureService) async throws -> GoScreenLabels {
        let frame = try await capture.latestFrame()
        return GoScreenLabels.recognize(in: frame.image)
    }

    /// Tencent's result card has a high-luminance centre panel. This local
    /// check is only a fallback when OCR misses both the stylized “负” glyph
    /// and tiny action labels; it must pass before the card-close fallback is
    /// ever used.
    private func terminalResultCardIsVisible(_ capture: WindowCaptureService) async throws -> Bool {
        let frame = try await capture.latestFrame()
        return Self.hasBrightCentralResultCard(frame.image)
    }

    private func isTencentResultCardVisible(
        labels: GoScreenLabels,
        capture: WindowCaptureService
    ) async -> Bool {
        let hasBrightCentralCard = (try? await terminalResultCardIsVisible(capture)) == true
        return labels.contains("对局结束")
            || (labels.contains("确定") && labels.contains("继续"))
            || hasBrightCentralCard
    }

    private func requiresTencentPaidConfirmation(_ labels: GoScreenLabels) -> Bool {
        TencentGoModalClassifier.requiresPaidConfirmation(ocrTexts: labels.values.map(\.text))
    }

    private func throwIfTencentPaidConfirmation(_ labels: GoScreenLabels) throws {
        guard !requiresTencentPaidConfirmation(labels) else {
            throw GridTargetBootstrapError.paidConfirmationRequired
        }
    }

    /// The caller reaches this only after an explicit cockpit confirmation.
    /// The click is bound to the already-detected Tencent paid-match dialog;
    /// no coordinate fallback is used on an unclassified screen.
    private func resolveTencentPaidConfirmationIfAuthorized(
        labels: inout GoScreenLabels,
        capture: WindowCaptureService,
        windowFrame: CGRect,
        authorizingTencentPaidMatch: Bool
    ) async throws {
        guard requiresTencentPaidConfirmation(labels) else { return }
        guard authorizingTencentPaidMatch else {
            throw GridTargetBootstrapError.paidConfirmationRequired
        }
        try await postClick(
            label: labels.best("确定") ?? labels.best("确认"),
            fallback: CGPoint(x: 0.58, y: 0.595),
            in: windowFrame
        )
        labels = try await waitForLabels(capture, timeout: .seconds(3)) {
            !self.requiresTencentPaidConfirmation($0)
        }
    }

    private static func hasBrightCentralResultCard(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 3, image.bytesPerRow >= image.width * bytesPerPixel else { return false }
        let samples: [(CGFloat, CGFloat)] = [
            (0.43, 0.36), (0.57, 0.36), (0.43, 0.58), (0.57, 0.58)
        ]
        let brightCount = samples.reduce(into: 0) { count, point in
            let x = min(image.width - 1, max(0, Int(point.0 * CGFloat(image.width))))
            let y = min(image.height - 1, max(0, Int(point.1 * CGFloat(image.height))))
            let index = y * image.bytesPerRow + x * bytesPerPixel
            let red = Double(bytes[index]) / 255
            let green = Double(bytes[index + 1]) / 255
            let blue = Double(bytes[index + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if luminance > 0.82 { count += 1 }
        }
        return brightCount >= 3
    }

    private func waitForLabels(
        _ capture: WindowCaptureService,
        timeout: Duration,
        condition: (GoScreenLabels) -> Bool
    ) async throws -> GoScreenLabels {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latest = try await currentLabels(capture)
        while clock.now < deadline {
            if condition(latest) { return latest }
            try await Task.sleep(for: .milliseconds(120))
            latest = try await currentLabels(capture)
        }
        if condition(latest) { return latest }
        throw GridTargetBootstrapError.noVisualResponse
    }

    /// OCR is an additional page proof, not the authority for whether the
    /// cockpit may use a documented public control.  Tencent's Unity text can
    /// be absent from one or two stream frames while the page itself is stable;
    /// in that case retain the current labels and use the narrow, page-specific
    /// fallback point supplied by the caller rather than abandoning a known
    /// local-client launch sequence.
    private func labelsAfterWaiting(
        _ capture: WindowCaptureService,
        timeout: Duration,
        condition: (GoScreenLabels) -> Bool
    ) async -> GoScreenLabels {
        if let labels = try? await waitForLabels(capture, timeout: timeout, condition: condition) {
            return labels
        }
        return (try? await currentLabels(capture)) ?? GoScreenLabels(values: [])
    }

    private func postClick(normalized: CGPoint, in windowFrame: CGRect) async throws {
        let point = CGPoint(
            x: windowFrame.minX + normalized.x * windowFrame.width,
            y: windowFrame.minY + normalized.y * windowFrame.height
        )
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw GridTargetBootstrapError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(35))
        up.post(tap: .cghidEventTap)
    }

    private func postClick(label: GoScreenLabel?, fallback: CGPoint, in windowFrame: CGRect) async throws {
        try await postClick(normalized: label?.centre ?? fallback, in: windowFrame)
    }
}

private struct GoScreenLabel: Sendable {
    let text: String
    /// Window-relative, top-left origin coordinates.
    let centre: CGPoint
}

private struct GoScreenLabels: Sendable {
    let values: [GoScreenLabel]

    func contains(_ text: String) -> Bool {
        values.contains { Self.normalize($0.text).contains(Self.normalize(text)) }
    }

    func best(_ text: String, preferLowerHalf: Bool = false) -> GoScreenLabel? {
        let needle = Self.normalize(text)
        let contains = values.filter { Self.normalize($0.text).contains(needle) }
        // Prefer a literal control label over a longer modal sentence such as
        // “确定认输吗？”.  The latter is a heading, not the action button.
        let matches = {
            let exact = contains.filter { Self.normalize($0.text) == needle }
            return exact.isEmpty ? contains : exact
        }()
        guard !matches.isEmpty else { return nil }
        if preferLowerHalf, let lower = matches.filter({ $0.centre.y > 0.55 }).max(by: { $0.centre.y < $1.centre.y }) {
            return lower
        }
        return matches.max(by: { $0.text.count < $1.text.count })
    }

    static func recognize(in image: CGImage) -> GoScreenLabels {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return GoScreenLabels(values: []) }
        let values = (request.results ?? []).compactMap { observation -> GoScreenLabel? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = observation.boundingBox
            return GoScreenLabel(
                text: candidate.string,
                centre: CGPoint(x: rect.midX, y: 1 - rect.midY)
            )
        }
        return GoScreenLabels(values: values)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isNewline }
    }
}
