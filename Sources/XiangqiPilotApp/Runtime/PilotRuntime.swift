import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import XiangqiCore

enum SetupStep: Int, CaseIterable, Sendable {
    case permissions
    case window
    case calibration
    case position
    case ready

    var title: String {
        switch self {
        case .permissions: return "授权"
        case .window: return "选择窗口"
        case .calibration: return "标定棋盘"
        case .position: return "确认局面"
        case .ready: return "开始对局"
        }
    }
}

enum BoardOrientation: String, CaseIterable, Identifiable, Sendable {
    case redAtBottom
    case redAtTop

    var id: String { rawValue }
    var title: String { self == .redAtBottom ? "红方在下" : "红方在上" }
}

struct NormalizedBoardCorners: Equatable, Sendable {
    var topLeft = CGPoint(x: 0.10, y: 0.06)
    var topRight = CGPoint(x: 0.90, y: 0.06)
    var bottomLeft = CGPoint(x: 0.10, y: 0.94)
    var bottomRight = CGPoint(x: 0.90, y: 0.94)
}

@MainActor
final class PilotRuntime: ObservableObject {
    @Published var setupStep: SetupStep = .permissions
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var permissionMayRequireRelaunch = false
    @Published var permissionIdentityIsStable = false
    @Published var availableWindows: [CapturableWindow] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var latestImage: NSImage?
    @Published var normalizedCorners = NormalizedBoardCorners()
    @Published var orientation: BoardOrientation = .redAtBottom
    @Published var sideToMove: Side = .red
    @Published var isBusy = false
    @Published var statusMessage = "正在检查系统权限…"
    @Published var blockingError: String?
    @Published var recognitionWarnings: [String] = []
    @Published var recognizedPieceCount = 0
    @Published var positionIsTrusted = false

    let presentation: PilotPresentationModel

    private let capture = WindowCaptureService()
    private let clickExecutor = ClickExecutor()
    private let recognizer = XiangqiVisionRecognizer()
    private let localEngine = AlphaBetaEngine()
    private let sessionMachine = SessionStateMachine()
    private let sessionStore = SessionStore()
    private var capturePollingTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var calibration: BoardCalibration?
    private var latestCapturedFrame: CapturedFrame?
    private var game = Game()
    private var session: XiangqiSessionRecord?

    init(presentation: PilotPresentationModel = .mock) {
        self.presentation = presentation
        presentation.source = WindowSource(
            id: "unselected",
            applicationName: "尚未选择窗口",
            windowTitle: "完成首次设置后开始",
            isLocked: false
        )
        presentation.phase = .observing
        presentation.isPaused = true
        wirePresentationActions()
    }

    deinit {
        capturePollingTask?.cancel()
        analysisTask?.cancel()
    }

    func bootstrap() async {
        refreshPermissionState()
        if hasScreenRecordingPermission && hasAccessibilityPermission {
            setupStep = .window
            await refreshWindows()
        } else {
            statusMessage = "需要屏幕录制和辅助功能权限"
        }
    }

    func refreshPermissionState() {
        let snapshot = MacPermissionsService.currentSnapshot()
        hasScreenRecordingPermission = snapshot.screenRecording == .granted
        hasAccessibilityPermission = snapshot.accessibility == .granted
        permissionMayRequireRelaunch = snapshot.screenRecordingMayRequireRelaunch
        permissionIdentityIsStable = snapshot.codeIdentity.isStableForTCC
        if hasScreenRecordingPermission && hasAccessibilityPermission && setupStep == .permissions {
            setupStep = .window
            statusMessage = "权限已就绪，请选择象棋窗口"
        } else if permissionMayRequireRelaunch {
            statusMessage = "系统已接受授权；请重新启动同一个应用以让权限生效"
        } else if !permissionIdentityIsStable {
            statusMessage = "当前应用签名身份不稳定，重新构建后可能需要再次授权"
        }
    }

    func requestScreenRecordingPermission() {
        _ = MacPermissionsService.requestScreenRecording()
        refreshPermissionState()
    }

    func requestAccessibilityPermission() {
        _ = MacPermissionsService.requestAccessibility()
        refreshPermissionState()
    }

    func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            blockingError = "当前不是从“棋局驾驶舱.app”启动，无法安全重启"
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.blockingError = "重新启动失败：\(error.localizedDescription)"
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func refreshWindows() async {
        refreshPermissionState()
        guard hasScreenRecordingPermission else {
            setupStep = .permissions
            blockingError = "请先授予屏幕录制权限"
            return
        }
        isBusy = true
        blockingError = nil
        defer { isBusy = false }
        do {
            availableWindows = try await capture.refreshAvailableWindows()
                .filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
            statusMessage = availableWindows.isEmpty
                ? "没有找到可捕获窗口"
                : "找到 \(availableWindows.count) 个可选窗口"
        } catch {
            blockingError = error.localizedDescription
        }
    }

    func selectWindow(_ window: CapturableWindow) async {
        isBusy = true
        blockingError = nil
        do {
            let target = try await capture.lockWindow(window.windowID)
            selectedWindowID = window.windowID
            presentation.source = WindowSource(
                id: String(window.windowID),
                applicationName: target.applicationName,
                windowTitle: target.title.isEmpty ? "未命名窗口" : target.title,
                isLocked: true
            )
            try await waitForFirstFrame()
            startCapturePolling()
            setupStep = .calibration
            statusMessage = "请把四个角点拖到棋盘最外侧交叉点"
        } catch {
            blockingError = error.localizedDescription
        }
        isBusy = false
    }

    func confirmCalibration() async {
        guard let frame = latestCapturedFrame,
              let liveWindow = frame.liveWindowGeometry else {
            blockingError = "尚未获取到稳定窗口画面"
            return
        }
        do {
            let size = frame.imageSize
            let corners = BoardCorners(
                topLeft: CGPoint(x: normalizedCorners.topLeft.x * size.width,
                                 y: normalizedCorners.topLeft.y * size.height),
                topRight: CGPoint(x: normalizedCorners.topRight.x * size.width,
                                  y: normalizedCorners.topRight.y * size.height),
                bottomLeft: CGPoint(x: normalizedCorners.bottomLeft.x * size.width,
                                    y: normalizedCorners.bottomLeft.y * size.height),
                bottomRight: CGPoint(x: normalizedCorners.bottomRight.x * size.width,
                                     y: normalizedCorners.bottomRight.y * size.height)
            )
            calibration = try BoardCalibration(
                corners: corners,
                imageSize: size,
                windowFrame: liveWindow.frame
            )
            setupStep = .position
            statusMessage = "正在识别任意象棋局面…"
            await recognizeCurrentPosition()
        } catch {
            blockingError = error.localizedDescription
        }
    }

    func recognizeCurrentPosition() async {
        guard let frame = latestCapturedFrame, let calibration else {
            blockingError = "请先完成棋盘标定"
            return
        }
        isBusy = true
        presentation.phase = .recognizing
        blockingError = nil
        defer { isBusy = false }

        do {
            let geometry = recognitionGeometry(from: calibration)
            let snapshot = try await recognizer.recognize(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )
            recognitionWarnings = snapshot.warnings
            recognizedPieceCount = snapshot.pieces.count
            let position = try makePosition(from: snapshot)
            game.reset(to: position)
            positionIsTrusted = !snapshot.requiresHumanReview
            presentation.confidence = snapshot.confidence
            synchronizePresentation(position: position)
            statusMessage = snapshot.requiresHumanReview
                ? "识别完成，请在数字棋盘上确认或纠正"
                : "局面已通过本地视觉识别"
            await analyzeCurrentPosition()
        } catch {
            positionIsTrusted = false
            blockingError = "局面识别需要人工确认：\(error.localizedDescription)"
            presentation.confidence = 0
            presentation.phase = .recognizing
        }
    }

    func useStandardPositionForCorrection() async {
        game.reset(to: .standard)
        recognitionWarnings = ["已载入标准局面，请根据画面修正"]
        recognizedPieceCount = 32
        presentation.confidence = 1
        positionIsTrusted = false
        synchronizePresentation(position: game.position)
        await analyzeCurrentPosition()
    }

    func editPiece(at coordinate: BoardCoordinate, side: XiangqiSide?, glyph: String?) {
        presentation.pieces.removeAll { $0.coordinate == coordinate }
        if let side, let glyph {
            presentation.pieces.append(
                BoardPiece(side: side, character: glyph, column: coordinate.column, row: coordinate.row)
            )
        }
        recognizedPieceCount = presentation.pieces.count
        positionIsTrusted = false
    }

    func commitManualPosition() async {
        do {
            let placements = try presentation.pieces.map { boardPiece -> Placement in
                let square = internalSquare(for: boardPiece.coordinate)
                let side: Side = boardPiece.side == .red ? .red : .black
                guard let kind = pieceKind(for: boardPiece.character) else {
                    throw XiangqiError.invalidFEN("未知棋子：\(boardPiece.character)")
                }
                return Placement(Piece(side: side, kind: kind), at: square)
            }
            let board = try Board(placements: placements)
            guard board.generalSquare(for: .red) != nil,
                  board.generalSquare(for: .black) != nil else {
                throw XiangqiError.invalidFEN("任意局面必须同时包含红帅和黑将")
            }
            let position = Position(board: board, sideToMove: sideToMove)
            game.reset(to: position)
            recognitionWarnings = []
            presentation.confidence = 1
            positionIsTrusted = true
            synchronizePresentation(position: position)
            await analyzeCurrentPosition()
            statusMessage = "人工校正已设为新的可信局面"
        } catch {
            blockingError = error.localizedDescription
        }
    }

    func completeSetup() async {
        guard calibration != nil else {
            blockingError = "请先完成棋盘标定"
            return
        }
        guard positionIsTrusted else {
            blockingError = "请先应用人工校正，将当前局面设为可信基准"
            return
        }
        setupStep = .ready
        presentation.isPaused = false
        presentation.phase = .observing
        try? await clickExecutor.arm()
        let newSession = XiangqiSessionRecord(
            title: "中国象棋 \(Date().formatted(date: .abbreviated, time: .shortened))",
            targetApplicationName: presentation.source.applicationName,
            targetWindowTitle: presentation.source.windowTitle,
            initialFEN: game.position.fen,
            currentFEN: game.position.fen
        )
        session = newSession
        try? await sessionStore.save(newSession)
        statusMessage = "象棋视觉驾驶舱已就绪"
    }

    func analyzeCurrentPosition(level: ThinkingLevel = .standard) async {
        analysisTask?.cancel()
        let position = game.position
        presentation.phase = .thinking
        let task = Task { [localEngine] in
            try await localEngine.analyze(position: position, level: level, maxCandidates: 3)
        }
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await task.value
                guard self.game.position.key == analysis.positionKey else { return }
                self.applyAnalysis(analysis)
            } catch is CancellationError {
                return
            } catch {
                self.blockingError = "引擎分析失败：\(error.localizedDescription)"
                self.presentation.phase = .observing
            }
        }
    }

    private func execute(_ candidate: CandidateMove) async {
        guard let move = Move(ucci: candidate.id),
              game.position.legalMoves.contains(move),
              let calibration,
              let frame = latestCapturedFrame else {
            pause(reason: "候选着法已过期或不合法")
            return
        }
        let positionBefore = game.position
        let expected: Position
        do {
            expected = try positionBefore.applying(move)
        } catch {
            pause(reason: error.localizedDescription)
            return
        }

        do {
            presentation.phase = .acting
            try await clickExecutor.arm()
            let visualFrom = visualCoordinate(for: move.from)
            let visualTo = visualCoordinate(for: move.to)
            let clickMove = XiangqiClickMove(
                source: try XiangqiGridPoint(file: visualFrom.column, rank: visualFrom.row),
                destination: try XiangqiGridPoint(file: visualTo.column, rank: visualTo.row)
            )
            let binding = ClickActionBinding(
                ownerPID: frame.target.ownerPID,
                windowID: frame.target.windowID,
                frameSequence: frame.sequence,
                frameContentFingerprint: frame.contentFingerprint,
                recognizedBoardStateHash: positionHash(positionBefore),
                geometryHash: calibration.geometryHash
            )
            let receipt = try await clickExecutor.execute(
                clickMove,
                binding: binding,
                calibration: calibration,
                capture: capture
            )
            presentation.phase = .verifying
            let verifiedPosition = try await waitForExpectedPosition(expected, after: receipt.beforeFrameSequence)
            _ = try await clickExecutor.verify(
                receipt,
                afterBoardStateHash: positionHash(verifiedPosition),
                capture: capture
            )
            _ = try game.play(move)
            synchronizePresentation(position: game.position)
            await recordExecutedMove(move, before: positionBefore, after: game.position)
            await analyzeCurrentPosition()
        } catch {
            await clickExecutor.pause(.verificationFailed(error.localizedDescription))
            pause(reason: error.localizedDescription)
        }
    }

    private func waitForExpectedPosition(_ expected: Position, after sequence: UInt64) async throws -> Position {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let frame = try? await capture.latestFrame(),
               frame.sequence > sequence,
               frame.isStable(),
               let calibration {
                let snapshot = try await recognizer.recognize(
                    image: frame.image,
                    frameSequence: frame.sequence,
                    geometry: recognitionGeometry(from: calibration)
                )
                if let position = try? makePosition(from: snapshot),
                   position.board == expected.board,
                   position.sideToMove == expected.sideToMove {
                    return position
                }
            }
            try await Task.sleep(for: .milliseconds(90))
        }
        throw ClickExecutorError.verificationBoardStateUnchanged
    }

    private func applyAnalysis(_ analysis: EngineAnalysis) {
        let candidates = analysis.candidates.map { candidate -> CandidateMove in
            let origin = visualCoordinate(for: candidate.move.from)
            let target = visualCoordinate(for: candidate.move.to)
            return CandidateMove(
                id: candidate.move.ucci,
                notation: displayNotation(for: candidate.move),
                origin: origin,
                target: target,
                score: confidencePercent(for: candidate.score),
                evaluation: evaluationText(candidate.score),
                reason: candidate.principalVariation.dropFirst().prefix(3).map(\.ucci).joined(separator: " ").nilIfEmpty ?? "本地引擎首选"
            )
        }
        presentation.candidates = candidates.isEmpty ? [.unavailable] : candidates
        presentation.selectedCandidateID = presentation.candidates[0].id
        presentation.phase = candidates.isEmpty ? .observing : .previewing
    }

    private func synchronizePresentation(position: Position) {
        presentation.pieces = position.board.placements.map { placement in
            let coordinate = visualCoordinate(for: placement.square)
            return BoardPiece(
                side: placement.piece.side == .red ? .red : .black,
                character: glyph(for: placement.piece),
                column: coordinate.column,
                row: coordinate.row
            )
        }
        presentation.phase = .thinking
    }

    private func makePosition(from snapshot: XiangqiRecognitionSnapshot) throws -> Position {
        let placements = try snapshot.pieces.map { recognized -> Placement in
            let visual = BoardCoordinate(column: recognized.file, row: recognized.rank)
            let square = internalSquare(for: visual)
            guard recognized.side != .unknown else {
                throw XiangqiError.invalidFEN("有棋子颜色无法确认")
            }
            let side: Side = recognized.side == .red ? .red : .black
            let kind: PieceKind
            switch recognized.kind {
            case .general: kind = .general
            case .advisor: kind = .advisor
            case .elephant: kind = .elephant
            case .horse: kind = .horse
            case .chariot: kind = .chariot
            case .cannon: kind = .cannon
            case .soldier: kind = .soldier
            }
            return Placement(Piece(side: side, kind: kind), at: square)
        }
        let board = try Board(placements: placements)
        guard board.generalSquare(for: .red) != nil, board.generalSquare(for: .black) != nil else {
            throw XiangqiError.invalidFEN("必须确认红帅和黑将")
        }
        return Position(board: board, sideToMove: sideToMove)
    }

    private func recognitionGeometry(from calibration: BoardCalibration) -> RecognitionBoardGeometry {
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

    private func visualCoordinate(for square: Square) -> BoardCoordinate {
        switch orientation {
        case .redAtBottom: return BoardCoordinate(column: square.file, row: square.rank)
        case .redAtTop: return BoardCoordinate(column: 8 - square.file, row: 9 - square.rank)
        }
    }

    private func internalSquare(for visual: BoardCoordinate) -> Square {
        switch orientation {
        case .redAtBottom: return Square(file: visual.column, rank: visual.row)
        case .redAtTop: return Square(file: 8 - visual.column, rank: 9 - visual.row)
        }
    }

    private func glyph(for piece: Piece) -> String {
        switch (piece.side, piece.kind) {
        case (.red, .general): return "帥"
        case (.black, .general): return "將"
        case (.red, .advisor): return "仕"
        case (.black, .advisor): return "士"
        case (.red, .elephant): return "相"
        case (.black, .elephant): return "象"
        case (.red, .horse): return "馬"
        case (.black, .horse): return "馬"
        case (.red, .chariot): return "車"
        case (.black, .chariot): return "車"
        case (.red, .cannon): return "炮"
        case (.black, .cannon): return "砲"
        case (.red, .soldier): return "兵"
        case (.black, .soldier): return "卒"
        }
    }

    private func pieceKind(for glyph: String) -> PieceKind? {
        switch glyph {
        case "帥", "將", "将": return .general
        case "仕", "士": return .advisor
        case "相", "象": return .elephant
        case "馬", "马", "傌": return .horse
        case "車", "车", "俥": return .chariot
        case "炮", "砲": return .cannon
        case "兵", "卒": return .soldier
        default: return nil
        }
    }

    private func displayNotation(for move: Move) -> String {
        guard let piece = game.position.board[move.from] else { return move.ucci }
        return "\(glyph(for: piece)) \(move.from.ucci)→\(move.to.ucci)"
    }

    private func confidencePercent(for score: Int) -> Int {
        let scaled = 50 + Int(45 * tanh(Double(score) / 600))
        return min(99, max(1, scaled))
    }

    private func evaluationText(_ score: Int) -> String {
        score >= 0 ? "+\(String(format: "%.2f", Double(score) / 100))" : String(format: "%.2f", Double(score) / 100)
    }

    private func positionHash(_ position: Position) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in position.fen.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func waitForFirstFrame() async throws {
        for _ in 0..<100 {
            if let frame = try? await capture.latestFrame() {
                updateLatestFrame(frame)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WindowCaptureError.noFrameAvailable
    }

    private func startCapturePolling() {
        capturePollingTask?.cancel()
        capturePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let frame = try? await self.capture.latestFrame() {
                    self.updateLatestFrame(frame)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func updateLatestFrame(_ frame: CapturedFrame) {
        latestCapturedFrame = frame
        let image = NSImage(cgImage: frame.image, size: frame.imageSize)
        latestImage = image
        presentation.liveImage = image
    }

    private func wirePresentationActions() {
        presentation.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            Task { @MainActor in
                if paused { await self.clickExecutor.pause(.userRequested) }
                else { try? await self.clickExecutor.arm() }
            }
        }
        presentation.onEmergencyStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.clickExecutor.pause(.manualTakeover) }
        }
        presentation.onResumeAfterStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.recognizeCurrentPosition() }
        }
        presentation.onRecognizePosition = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.recognizeCurrentPosition() }
        }
        presentation.onApplyCorrection = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.commitManualPosition() }
        }
        presentation.onConfirmMove = { [weak self] candidate in
            guard let self else { return }
            Task { @MainActor in await self.execute(candidate) }
        }
        presentation.onRecover = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.recognizeCurrentPosition() }
        }
        presentation.onEditPiece = { [weak self] coordinate, side, glyph in
            self?.editPiece(at: coordinate, side: side, glyph: glyph)
        }
    }

    private func pause(reason: String) {
        presentation.isPaused = true
        presentation.phase = .observing
        blockingError = reason
        statusMessage = "已安全暂停：\(reason)"
    }

    private func recordExecutedMove(_ move: Move, before: Position, after: Position) async {
        guard var current = session else { return }
        current.currentFEN = after.fen
        current.moves.append(SessionMoveRecord(
            ply: current.moves.count + 1,
            fenBefore: before.fen,
            move: move.ucci,
            fenAfter: after.fen,
            source: .localEngine,
            confidence: presentation.confidence,
            thinkingMilliseconds: 0,
            outcome: .executed
        ))
        session = current
        try? await sessionStore.save(current)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
