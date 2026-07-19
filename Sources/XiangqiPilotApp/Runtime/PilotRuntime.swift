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

enum PositionVerificationPolicy {
    /// A captured board has no reliable turn indicator. The expected position
    /// comes from the already-validated legal move, so visual verification must
    /// compare board contents and must not reuse the setup screen's stale turn.
    static func matches(observed: Position, expected: Position) -> Bool {
        observed.board == expected.board
    }

    /// Some stylized boards yield a trustworthy but incomplete OCR result.
    /// Accept that fallback only when every recognized piece agrees with the
    /// legal expected board, both generals and the moved destination are
    /// recognized, and the board-only pixel delta is exactly the move's two
    /// endpoints. This remains substantially stricter than "the image changed".
    static func matches(
        snapshot: XiangqiRecognitionSnapshot,
        expected: Position,
        move: Move,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange,
        minimumCoverage: Double = 0.68
    ) -> Bool {
        let source = visualCoordinate(for: move.from, orientation: orientation)
        let destination = visualCoordinate(for: move.to, orientation: orientation)
        let expectedChangedCells: Set<BoardCellCoordinate> = [source, destination]
        let changedCells = Set(visualChange.cells.map(\.coordinate))
        guard changedCells == expectedChangedCells else { return false }

        var observedBySquare: [Square: Piece] = [:]
        for recognized in snapshot.pieces {
            guard let piece = piece(from: recognized) else { return false }
            let square = internalSquare(
                file: recognized.file,
                rank: recognized.rank,
                orientation: orientation
            )
            guard observedBySquare[square] == nil,
                  expected.board[square] == piece else { return false }
            observedBySquare[square] = piece
        }

        guard observedBySquare[move.from] == nil,
              let destinationPiece = expected.board[move.to],
              observedBySquare[move.to] == destinationPiece else { return false }

        for side in Side.allCases {
            guard let general = expected.board.generalSquare(for: side),
                  observedBySquare[general] == expected.board[general] else { return false }
        }

        let expectedCount = expected.board.pieceCount()
        guard expectedCount > 0 else { return false }
        return Double(observedBySquare.count) / Double(expectedCount) >= minimumCoverage
    }

    private static func visualCoordinate(
        for square: Square,
        orientation: BoardOrientation
    ) -> BoardCellCoordinate {
        switch orientation {
        case .redAtBottom:
            return BoardCellCoordinate(file: square.file, rank: square.rank)
        case .redAtTop:
            return BoardCellCoordinate(file: 8 - square.file, rank: 9 - square.rank)
        }
    }

    private static func internalSquare(
        file: Int,
        rank: Int,
        orientation: BoardOrientation
    ) -> Square {
        switch orientation {
        case .redAtBottom: return Square(file: file, rank: rank)
        case .redAtTop: return Square(file: 8 - file, rank: 9 - rank)
        }
    }

    private static func piece(from recognized: RecognizedPiece) -> Piece? {
        let side: Side
        switch recognized.side {
        case .red: side = .red
        case .black: side = .black
        case .unknown: return nil
        }
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
        return Piece(side: side, kind: kind)
    }
}

enum StandardPositionRecognitionPolicy {
    /// OCR on stylized skins often gets piece colours wrong while preserving
    /// intersection and piece kind. Recover the canonical opening only when a
    /// high-coverage set of unique detections agrees with every standard
    /// square and kind; a moved piece at a different kind's square is rejected.
    static func matches(
        snapshot: XiangqiRecognitionSnapshot,
        orientation: BoardOrientation,
        minimumPieceCount: Int = 28
    ) -> Bool {
        guard snapshot.pieces.count >= minimumPieceCount else { return false }
        var expected: [BoardCellCoordinate: PieceKind] = [:]
        for placement in Position.standard.board.placements {
            let coordinate: BoardCellCoordinate
            switch orientation {
            case .redAtBottom:
                coordinate = BoardCellCoordinate(
                    file: placement.square.file,
                    rank: placement.square.rank
                )
            case .redAtTop:
                coordinate = BoardCellCoordinate(
                    file: 8 - placement.square.file,
                    rank: 9 - placement.square.rank
                )
            }
            expected[coordinate] = placement.piece.kind
        }

        var seen: Set<BoardCellCoordinate> = []
        for piece in snapshot.pieces {
            let coordinate = BoardCellCoordinate(file: piece.file, rank: piece.rank)
            guard seen.insert(coordinate).inserted,
                  expected[coordinate] == coreKind(piece.kind) else { return false }
        }
        return true
    }

    private static func coreKind(_ kind: RecognizedPieceKind) -> PieceKind {
        switch kind {
        case .general: .general
        case .advisor: .advisor
        case .elephant: .elephant
        case .horse: .horse
        case .chariot: .chariot
        case .cannon: .cannon
        case .soldier: .soldier
        }
    }
}

struct NormalizedBoardCorners: Equatable, Sendable {
    var topLeft = CGPoint(x: 0.10, y: 0.06)
    var topRight = CGPoint(x: 0.90, y: 0.06)
    var bottomLeft = CGPoint(x: 0.10, y: 0.94)
    var bottomRight = CGPoint(x: 0.90, y: 0.94)
}

private struct RecoveryCandidate {
    let position: Position
    let signature: BoardFrameSignature
    let confidence: Double
    let source: PositionRecoverySource
    let canAutoApply: Bool
}

private enum RecoveryTimeoutError: LocalizedError {
    case model(String)

    var errorDescription: String? {
        switch self {
        case .model(let label): return "\(label)在限定时间内没有返回"
        }
    }
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
    @Published var blockingError: String? {
        didSet {
            guard let blockingError, blockingError != oldValue else { return }
            PilotDiagnosticLogger.blockingError(blockingError)
        }
    }
    @Published var recognitionWarnings: [String] = []
    @Published var recognizedPieceCount = 0
    @Published var positionIsTrusted = false {
        didSet { presentation.isPositionTrusted = positionIsTrusted }
    }

    let presentation: PilotPresentationModel

    private let capture = WindowCaptureService()
    private let clickExecutor = ClickExecutor()
    private let recognizer = XiangqiVisionRecognizer()
    private let boardDifferencer = BoardFrameDifferencer()
    private let modelGateway = ModelGateway()
    private let pricingService = AlibabaPricingService()
    private let settingsStore = AppSettingsStore()
    private let apiKeyStore = APIKeyStore()
    private let localEngine = AlphaBetaEngine()
    private lazy var pikafishEngine = UCCIEngineClient(
        executableURL: Self.pikafishExecutableURL(),
        engineProtocol: .uci,
        options: [
            UCCIEngineOption(name: "Threads", value: "2"),
            UCCIEngineOption(name: "Hash", value: "128")
        ]
    )
    private let sessionMachine = SessionStateMachine()
    private let sessionStore = SessionStore()
    private var capturePollingTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var calibration: BoardCalibration?
    private var latestCapturedFrame: CapturedFrame?
    private var trustedBoardSignature: BoardFrameSignature?
    private var lastTrustedPosition: Position?
    private var recoveryCandidate: RecoveryCandidate?
    private var recoveryTask: Task<Void, Never>?
    private var rejectedChangeKey: String?
    private var rejectedChangeFirstSeenAt: TimeInterval?
    /// Prevents a failed recovery from immediately retrying the exact same
    /// unchanged board forever. A new visual pattern or a user retry clears it.
    private var recoveredOrAttemptedChangeKey: String?
    private var selectedBundleIdentifier: String?
    private var lastReconciledFrameSequence: UInt64 = 0
    /// A candidate may be published repeatedly while SwiftUI redraws.  Keep one
    /// pending automatic dispatch per exact board position so automatic mode
    /// cannot send duplicate clicks for the same move.
    private var automaticExecutionToken: String?
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
        presentation.pieces = []
        presentation.candidates = [.unavailable]
        presentation.events = []
        presentation.confidence = 0
        presentation.confidenceBasis = "尚未识别"
        presentation.isPositionTrusted = false
        presentation.gridDeviationPixels = nil
        presentation.lastModelBilling = nil
        presentation.modelSessionCostCNY = 0
        wirePresentationActions()
    }

    deinit {
        capturePollingTask?.cancel()
        analysisTask?.cancel()
        recoveryTask?.cancel()
    }

    func bootstrap() async {
        refreshPermissionState()
        await configureIntelligence()
        Task { [pricingService] in
            await pricingService.refreshFromOfficialSite()
        }
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
            selectedBundleIdentifier = window.bundleIdentifier
            normalizedCorners = Self.savedCorners(for: window.bundleIdentifier)
                ?? Self.cornerPreset(for: window.bundleIdentifier)
                ?? NormalizedBoardCorners()
            selectedWindowID = window.windowID
            presentation.source = WindowSource(
                id: String(window.windowID),
                applicationName: target.applicationName,
                windowTitle: target.title.isEmpty ? "未命名窗口" : target.title,
                isLocked: true
            )
            presentation.recordEvent(
                title: "目标窗口已锁定",
                detail: "\(target.applicationName) · windowID \(target.windowID)",
                symbolName: "macwindow.badge.plus",
                tone: .neutral
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
            Self.saveCorners(normalizedCorners, for: selectedBundleIdentifier)
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
            let signature = boardDifferencer.signature(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )

            if positionIsTrusted, let trustedBoardSignature {
                let visualChange = boardDifferencer.changes(
                    from: trustedBoardSignature,
                    to: signature,
                    minimumScore: 0.07
                )
                switch RecognitionTransitionPolicy.decide(
                    trusted: game.position,
                    orientation: orientation,
                    visualChange: visualChange
                ) {
                case .unchanged:
                    self.trustedBoardSignature = signature
                    statusMessage = "当前画面与可信局面一致，无需重新 OCR"
                    await analyzeCurrentPosition()
                    return
                case .legalMove(let move):
                    let before = game.position
                    _ = try game.play(move)
                    sideToMove = game.position.sideToMove
                    self.trustedBoardSignature = signature
                    presentation.confidence = 1
                    presentation.confidenceBasis = "合法着法差分"
                    synchronizePresentation(position: game.position)
                    await recordObservedMove(move, before: before, after: game.position)
                    statusMessage = "通过两个变化交点确认合法走法：\(move.ucci)"
                    await analyzeCurrentPosition()
                    return
                case .rejected:
                    recognitionWarnings = ["画面变化不是唯一的一步合法走法"]
                    blockingError = "棋盘变化已拦截：可信棋盘未被覆盖，请等待动画结束或人工核对"
                    presentation.phase = .observing
                    return
                }
            }

            let snapshot = try await recognizer.recognize(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )
            recognitionWarnings = snapshot.warnings
            recognizedPieceCount = snapshot.localOccupancy.count
            if !positionIsTrusted,
               StandardPositionRecognitionPolicy.matches(
                   snapshot: snapshot,
                   orientation: orientation
               ) {
                game.reset(to: .standard)
                sideToMove = .red
                positionIsTrusted = true
                recognizedPieceCount = 32
                recognitionWarnings = ["已通过高覆盖率占位与棋子类型校验恢复标准开局"]
                presentation.confidence = 1
                presentation.confidenceBasis = "标准开局规则恢复"
                trustedBoardSignature = signature
                synchronizePresentation(position: game.position)
                statusMessage = "已自动确认32枚标准开局"
                presentation.recordEvent(
                    title: "标准局面识别可信",
                    detail: "32枚棋子 · 红方走 · 本地视觉规则恢复",
                    symbolName: "checkmark.seal.fill",
                    tone: .success
                )
                await analyzeCurrentPosition()
                return
            }
            // A locally complete-looking board can still be wrong: OCR may
            // consistently miss a real piece and therefore report matching
            // piece/occupancy counts.  Any untrusted low-confidence board is
            // eligible for the cloud visual review, which is allowed to fill
            // only a small number of locally missed intersections.
            if !positionIsTrusted,
               snapshot.requiresHumanReview,
               await recognizePositionWithAlibabaModel(
                   frame: frame,
                   calibration: calibration,
                   signature: signature,
                   localSnapshot: snapshot
               ) {
                await analyzeCurrentPosition()
                return
            }
            let position = try makePosition(from: snapshot)
            if positionIsTrusted {
                let visualChange = trustedBoardSignature.map {
                    boardDifferencer.changes(from: $0, to: signature, minimumScore: 0.07)
                }
                switch RecognitionTransitionPolicy.decide(
                    trusted: game.position,
                    observed: position,
                    orientation: orientation,
                    visualChange: visualChange
                ) {
                case .unchanged:
                    trustedBoardSignature = signature
                    presentation.confidence = max(presentation.confidence, snapshot.confidence)
                    statusMessage = "当前画面与可信局面一致"
                case .legalMove(let move):
                    let before = game.position
                    _ = try game.play(move)
                    sideToMove = game.position.sideToMove
                    trustedBoardSignature = signature
                    presentation.confidence = snapshot.confidence
                    presentation.confidenceBasis = "本地视觉"
                    synchronizePresentation(position: game.position)
                    await recordObservedMove(move, before: before, after: game.position)
                    statusMessage = "已确认棋盘发生一步合法变化：\(move.ucci)"
                case .rejected:
                    recognitionWarnings.append("识别结果与可信局面不构成一步合法变化")
                    blockingError = "识别漂移已拦截：可信棋盘未被覆盖，请人工核对变化交点"
                    presentation.phase = .observing
                    return
                }
            } else {
                game.reset(to: position)
                positionIsTrusted = !snapshot.requiresHumanReview
                presentation.confidence = snapshot.confidence
                presentation.confidenceBasis = "本地视觉"
                synchronizePresentation(position: position)
                if positionIsTrusted { trustedBoardSignature = signature }
                statusMessage = snapshot.requiresHumanReview
                    ? "识别完成，请在数字棋盘上确认或纠正"
                    : "局面已通过本地视觉识别"
                presentation.recordEvent(
                    title: snapshot.requiresHumanReview ? "局面等待人工确认" : "局面识别可信",
                    detail: "\(position.board.pieceCount())枚棋子 · \(sideToMove == .red ? "红方" : "黑方")走 · 本地视觉",
                    symbolName: snapshot.requiresHumanReview ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                    tone: snapshot.requiresHumanReview ? .attention : .success
                )
            }
            await analyzeCurrentPosition()
        } catch {
            positionIsTrusted = false
            blockingError = "局面识别需要人工确认：\(error.localizedDescription)"
            presentation.confidence = 0
            presentation.confidenceBasis = "识别失败"
            presentation.phase = .recognizing
        }
    }

    func useStandardPositionForCorrection() async {
        game.reset(to: .standard)
        recognitionWarnings = ["已载入标准局面，请根据画面修正"]
        recognizedPieceCount = 32
        presentation.confidence = 1
        presentation.confidenceBasis = "待人工确认"
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
            presentation.confidenceBasis = "人工确认"
            positionIsTrusted = true
            blockingError = nil
            if let frame = latestCapturedFrame, let calibration {
                trustedBoardSignature = boardDifferencer.signature(
                    image: frame.image,
                    frameSequence: frame.sequence,
                    geometry: recognitionGeometry(from: calibration)
                )
            }
            lastTrustedPosition = position
            synchronizePresentation(position: position)
            await analyzeCurrentPosition()
            statusMessage = "人工校正已设为新的可信局面"
        } catch {
            blockingError = error.localizedDescription
        }
    }

    func beginPositionRecovery(reason: String? = nil) async {
        guard !presentation.isRecovering,
              let calibration,
              let initialFrame = latestCapturedFrame else { return }

        analysisTask?.cancel()
        await clickExecutor.pause(.manualTakeover)
        presentation.isPaused = true
        presentation.isRecovering = true
        presentation.phase = .recognizing
        presentation.recoveryNeedsAttention = true
        presentation.recoveryDetectedAt = presentation.recoveryDetectedAt ?? Date()
        presentation.recoveryReason = reason ?? presentation.recoveryReason
        presentation.lastTrustedPieceCount = (lastTrustedPosition ?? game.position).board.pieceCount()
        presentation.recoveryHasCandidate = false
        presentation.recoveryCandidatePieces = []
        presentation.recoveryCandidateSideToMove = nil
        presentation.recoveryCandidatePieceCount = nil
        presentation.recoveryDifferences = []
        presentation.recoveryConfidence = nil
        presentation.recoverySource = nil
        presentation.recoveryCanAutoApply = false
        presentation.recoveryProgressText = "正在等待稳定画面"
        recoveryCandidate = nil
        if reason == nil {
            recoveredOrAttemptedChangeKey = rejectedChangeKey
        }
        blockingError = nil
        statusMessage = "已暂停窗口操作，正在稳定画面并重新识别整盘…"

        defer {
            presentation.isRecovering = false
            recoveryTask = nil
        }

        do {
            try await Task.sleep(for: .milliseconds(220))
            presentation.recoveryProgressText = "正在检查棋盘是否稳定"
            let frame = (try? await capture.latestFrame()) ?? initialFrame
            let geometry = recognitionGeometry(from: calibration)
            let signature = boardDifferencer.signature(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )
            let initialSignature = boardDifferencer.signature(
                image: initialFrame.image,
                frameSequence: initialFrame.sequence,
                geometry: geometry
            )
            guard boardDifferencer.changes(
                from: initialSignature,
                to: signature,
                minimumScore: 0.035
            ).cells.isEmpty else {
                throw XiangqiError.invalidFEN("棋盘仍在动画或变化，请画面稳定后重试")
            }

            presentation.recoveryProgressText = "本地视觉正在识别90个交点"
            let snapshot = try await recognizer.recognize(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )
            guard snapshot.localOccupancy.count >= 2 else {
                throw XiangqiError.invalidFEN("当前画面没有足够棋子，疑似棋盘被遮挡；请关闭弹窗后重试")
            }
            let localPosition = try? makePosition(from: snapshot)
            presentation.recoveryProgressText = "本地识别完成，正在请求云端复核"
            let modelCandidates = await recognizeRecoveryCandidates(
                frame: frame,
                calibration: calibration,
                signature: signature,
                localSnapshot: snapshot
            )

            let selected: RecoveryCandidate?
            if let localPosition,
               let matchingModel = modelCandidates.first(where: { $0.position.board == localPosition.board }) {
                let canAutoApply = PositionRecoverySafetyPolicy.canAutoApply(
                    local: .init(position: localPosition, confidence: snapshot.confidence),
                    models: modelCandidates.map { .init(position: $0.position, confidence: $0.confidence) }
                )
                selected = RecoveryCandidate(
                    position: localPosition,
                    signature: matchingModel.signature,
                    confidence: min(snapshot.confidence, matchingModel.confidence),
                    source: .localAndAI,
                    canAutoApply: canAutoApply
                )
            } else if modelCandidates.count >= 2,
                      modelCandidates[0].position.board == modelCandidates[1].position.board {
                let canAutoApply = PositionRecoverySafetyPolicy.canAutoApply(
                    local: nil,
                    models: modelCandidates.map { .init(position: $0.position, confidence: $0.confidence) }
                )
                selected = RecoveryCandidate(
                    position: modelCandidates[1].position,
                    signature: modelCandidates[1].signature,
                    confidence: min(modelCandidates[0].confidence, modelCandidates[1].confidence),
                    source: .dualAI,
                    canAutoApply: canAutoApply
                )
            } else if let bestModel = modelCandidates.last {
                selected = RecoveryCandidate(
                    position: bestModel.position,
                    signature: bestModel.signature,
                    confidence: bestModel.confidence,
                    source: bestModel.source,
                    canAutoApply: false
                )
            } else if let localPosition, snapshot.confidence >= 0.96, !snapshot.requiresHumanReview {
                selected = RecoveryCandidate(
                    position: localPosition,
                    signature: signature,
                    confidence: snapshot.confidence,
                    source: .localVision,
                    canAutoApply: false
                )
            } else {
                selected = nil
            }

            guard let selected else {
                recognitionWarnings = snapshot.warnings
                blockingError = "整盘复核仍无法形成可信候选；请用“任意局面识别”手工修正"
                statusMessage = "自动纠错未通过安全校验，旧可信局面保持不变"
                presentation.phase = .observing
                presentation.recoveryProgressText = "未形成可信候选，可重试或人工校正"
                return
            }

            recoveryCandidate = selected
            publishRecoveryCandidate(selected)
            if selected.canAutoApply {
                await applyRecoveryCandidate(automatic: true)
            } else {
                statusMessage = "已生成纠错候选，请核对差异后应用"
                presentation.recoveryProgressText = "已生成候选，等待你确认"
                presentation.recordEvent(
                    title: "中盘纠错等待确认",
                    detail: "\(selected.source.rawValue) · \(selected.position.board.pieceCount())枚 · \(presentation.recoveryDifferences.count)处差异",
                    symbolName: "person.crop.circle.badge.questionmark",
                    tone: .attention
                )
            }
        } catch {
            blockingError = "中盘纠错失败：\(error.localizedDescription)"
            statusMessage = "旧可信局面未被覆盖，窗口操作保持暂停"
            presentation.phase = .observing
            presentation.recoveryProgressText = "识别已结束：\(error.localizedDescription)"
        }
    }

    func applyRecoveryCandidate(automatic: Bool = false) async {
        guard let candidate = recoveryCandidate else { return }
        analysisTask?.cancel()
        let chosenSide: Side = presentation.recoveryCandidateSideToMove == .black ? .black : .red
        let correctedPosition = Position(board: candidate.position.board, sideToMove: chosenSide)
        game.reset(to: correctedPosition)
        sideToMove = correctedPosition.sideToMove
        trustedBoardSignature = candidate.signature
        lastReconciledFrameSequence = candidate.signature.frameSequence
        lastTrustedPosition = correctedPosition
        positionIsTrusted = true
        recognizedPieceCount = candidate.position.board.pieceCount()
        presentation.confidence = candidate.confidence
        presentation.confidenceBasis = candidate.source.rawValue
        presentation.isPaused = true
        presentation.isEmergencyStopped = false
        presentation.phase = .previewing
        presentation.recoveryNeedsAttention = false
        synchronizePresentation(position: correctedPosition)
        recoveryCandidate = nil
        presentation.recoveryHasCandidate = false
        rejectedChangeKey = nil
        rejectedChangeFirstSeenAt = nil
        recoveredOrAttemptedChangeKey = nil
        blockingError = nil
        statusMessage = automatic
            ? "AI与本地识别一致，已自动纠正；保持暂停，请确认后继续"
            : "纠正局面已应用；保持暂停，请确认后继续"
        presentation.recordEvent(
            title: automatic ? "中盘局面已自动纠正" : "中盘局面已确认纠正",
            detail: "\(candidate.source.rawValue) · \(recognizedPieceCount)枚 · 保持暂停",
            symbolName: "checkmark.shield.fill",
            tone: .success
        )
        await analyzeCurrentPosition()
        presentation.isPaused = true
    }

    func discardRecoveryCandidate() async {
        recoveryCandidate = nil
        presentation.recoveryHasCandidate = false
        presentation.recoveryCandidatePieces = []
        presentation.recoveryCandidateSideToMove = nil
        presentation.recoveryCandidatePieceCount = nil
        presentation.recoveryDifferences = []
        presentation.recoveryConfidence = nil
        presentation.recoverySource = nil
        presentation.recoveryCanAutoApply = false
        presentation.recoveryProgressText = "已取消，保留最后可信局面"
        recoveredOrAttemptedChangeKey = rejectedChangeKey
        presentation.recoveryNeedsAttention = false
        presentation.isPaused = true
        presentation.phase = .observing
        statusMessage = "已保留最后可信局面，窗口操作继续锁定"
        presentation.recordEvent(
            title: "已放弃纠错候选",
            detail: "最后可信局面保持不变，仍处于暂停状态",
            symbolName: "arrow.uturn.backward.circle.fill",
            tone: .neutral
        )
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
        blockingError = nil
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
        presentation.recordEvent(
            title: "驾驶舱开始实时监控",
            detail: "\(game.position.board.pieceCount())枚棋子 · \(game.position.sideToMove == .red ? "红方" : "黑方")走",
            symbolName: "waveform.path.ecg",
            tone: .success
        )
    }

    func analyzeCurrentPosition(level: ThinkingLevel = .standard) async {
        analysisTask?.cancel()
        let position = game.position
        presentation.phase = .thinking
        let selectedEngine = presentation.engineSource
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                if selectedEngine == .ucci {
                    let result = try await self.pikafishEngine.analyze(
                        fen: position.fen,
                        timeMilliseconds: level.limits.timeLimitMilliseconds
                    )
                    try Task.checkCancellation()
                    guard self.game.position.key == position.key else { return }
                    try self.applyExternalAnalysis(result, position: position)
                    self.statusMessage = "Pikafish 已完成分析"
                } else {
                    let engine = self.localEngine
                    let analysis = try await Task.detached(priority: .userInitiated) {
                        try await engine.analyze(position: position, level: level, maxCandidates: 3)
                    }.value
                    try Task.checkCancellation()
                    guard self.game.position.key == analysis.positionKey else { return }
                    self.applyAnalysis(analysis)
                }
            } catch is CancellationError {
                return
            } catch {
                if selectedEngine == .ucci {
                    self.statusMessage = "Pikafish 暂不可用，已自动回退内置引擎"
                    let engine = self.localEngine
                    if let fallback = try? await Task.detached(priority: .userInitiated, operation: {
                        try await engine.analyze(position: position, level: level, maxCandidates: 3)
                    }).value,
                       self.game.position.key == fallback.positionKey {
                        self.applyAnalysis(fallback)
                        return
                    }
                }
                self.blockingError = "引擎分析失败：\(error.localizedDescription)"
                self.presentation.phase = .observing
            }
        }
    }

    private func applyExternalAnalysis(_ result: UCCIAnalysis, position: Position) throws {
        guard let move = Move(ucci: result.bestMove), position.legalMoves.contains(move) else {
            throw UCCIEngineError.malformedBestMove
        }
        let origin = visualCoordinate(for: move.from)
        let target = visualCoordinate(for: move.to)
        presentation.candidates = [CandidateMove(
            id: move.ucci,
            notation: displayNotation(for: move),
            origin: origin,
            target: target,
            score: confidencePercent(for: result.scoreCentipawns ?? 0),
            evaluation: evaluationText(result.scoreCentipawns ?? 0),
            reason: result.principalVariation.dropFirst().prefix(5).joined(separator: " ").nilIfEmpty
                ?? "Pikafish 深度 \(result.depth ?? 0)"
        )]
        presentation.selectedCandidateID = move.ucci
        presentation.phase = .previewing
        scheduleAutomaticExecutionIfEligible()
    }

    private func execute(_ candidate: CandidateMove) async {
        automaticExecutionToken = nil
        guard let move = Move(ucci: candidate.id),
              game.position.legalMoves.contains(move),
              let calibration else {
            pause(reason: "候选着法已过期或不合法")
            return
        }
        guard let target = await capture.lockedTarget() else {
            pause(reason: "目标窗口已消失")
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

        let actionStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            presentation.phase = .acting
            try await clickExecutor.arm()
            let preparationStartedAt = ProcessInfo.processInfo.systemUptime
            let frame = try await clickExecutor.prepareTargetForInput(
                ownerPID: target.ownerPID,
                windowID: target.windowID,
                calibration: calibration,
                capture: capture
            )
            PilotDiagnosticLogger.timing(
                "prepare_target",
                milliseconds: (ProcessInfo.processInfo.systemUptime - preparationStartedAt) * 1_000
            )
            let geometry = recognitionGeometry(from: calibration)
            let beforeBoardSignature = boardDifferencer.signature(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry
            )
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
                boardVisualSignature: beforeBoardSignature,
                boardGeometry: geometry,
                recognizedBoardStateHash: positionHash(positionBefore),
                geometryHash: calibration.geometryHash
            )
            let dispatchStartedAt = ProcessInfo.processInfo.systemUptime
            let receipt = try await clickExecutor.execute(
                clickMove,
                binding: binding,
                calibration: calibration,
                capture: capture
            )
            PilotDiagnosticLogger.timing(
                "dispatch_clicks",
                milliseconds: (ProcessInfo.processInfo.systemUptime - dispatchStartedAt) * 1_000
            )
            presentation.phase = .verifying
            statusMessage = "落子命令已送达，正在等待象棋巫师更新棋盘…"
            let verificationStartedAt = ProcessInfo.processInfo.systemUptime
            let verification = try await waitForExpectedPosition(
                expected,
                after: receipt.beforeFrameSequence,
                move: move,
                beforeBoardSignature: beforeBoardSignature
            )
            PilotDiagnosticLogger.timing(
                "wait_for_visual_move",
                milliseconds: (ProcessInfo.processInfo.systemUptime - verificationStartedAt) * 1_000
            )
            _ = try await clickExecutor.verify(
                receipt,
                afterBoardStateHash: positionHash(verification.position),
                capture: capture
            )
            _ = try game.play(move)
            sideToMove = game.position.sideToMove
            // Preserve the exact frame that proved this move. The target may
            // answer immediately; using a later frame here would silently
            // absorb that reply without applying it to the digital position.
            trustedBoardSignature = verification.signature
            lastReconciledFrameSequence = verification.signature.frameSequence
            synchronizePresentation(position: game.position)
            await recordExecutedMove(move, before: positionBefore, after: game.position)
            PilotDiagnosticLogger.timing(
                "confirmed_move_total",
                milliseconds: (ProcessInfo.processInfo.systemUptime - actionStartedAt) * 1_000
            )
            statusMessage = "数字棋盘已同步：\(move.ucci)"
            presentation.recordEvent(
                title: "落子执行并验证",
                detail: "\(move.ucci) · 数字棋盘已同步为\(game.position.board.pieceCount())枚",
                symbolName: "cursorarrow.click.2",
                tone: .success
            )
            await analyzeCurrentPosition()
        } catch {
            let diagnostic = PilotDiagnostic(error: error)
            await clickExecutor.pause(.verificationFailed(diagnostic.displayText))
            pause(reason: diagnostic.displayText)
        }
    }

    private func waitForExpectedPosition(
        _ expected: Position,
        after sequence: UInt64,
        move: Move,
        beforeBoardSignature: BoardFrameSignature
    ) async throws -> (position: Position, signature: BoardFrameSignature) {
        let clock = ContinuousClock()
        // Some target programs animate or think before committing a move. Keep
        // observing long enough to accept that delayed result, but make the hot
        // path cheap: board fingerprints first, OCR only for a settled complex
        // change. This also prevents OCR work from starving the target app.
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: .seconds(15))
        var lastProcessedSequence = sequence
        var lastChangedSignature: BoardFrameSignature?
        var complexChangeStableSince: ContinuousClock.Instant?
        var lastOCRSequence: UInt64?
        var announcedSlowTarget = false
        while clock.now < deadline {
            try Task.checkCancellation()
            if let frame = try? await capture.latestFrame(),
               frame.sequence > lastProcessedSequence,
               let calibration {
                lastProcessedSequence = frame.sequence
                let geometry = recognitionGeometry(from: calibration)
                let afterSignature = boardDifferencer.signature(
                    image: frame.image,
                    frameSequence: frame.sequence,
                    geometry: geometry
                )
                let visualChange = boardDifferencer.changes(
                    from: beforeBoardSignature,
                    to: afterSignature,
                    minimumScore: 0.07
                )
                let transition = RecognitionTransitionPolicy.decide(
                    trusted: game.position,
                    orientation: orientation,
                    visualChange: visualChange
                )
                if transition == .legalMove(move) {
                    PilotDiagnosticLogger.event(
                        "expected_move_detected_directly move=\(move.ucci) frame=\(frame.sequence)"
                    )
                    return (expected, afterSignature)
                }

                // An unchanged board cannot help OCR verification. Waiting here
                // is both faster and more accurate than repeatedly recognizing
                // the same 90 intersections.
                if visualChange.cells.isEmpty {
                    lastChangedSignature = nil
                    complexChangeStableSince = nil
                } else {
                    if let previous = lastChangedSignature {
                        let stillAnimating = !boardDifferencer.changes(
                            from: previous,
                            to: afterSignature,
                            minimumScore: 0.035
                        ).cells.isEmpty
                        if stillAnimating {
                            complexChangeStableSince = clock.now
                        }
                    } else {
                        complexChangeStableSince = clock.now
                    }
                    lastChangedSignature = afterSignature

                    let settled = complexChangeStableSince.map {
                        $0.duration(to: clock.now) >= .milliseconds(160)
                    } ?? false
                    if settled, lastOCRSequence != frame.sequence {
                        lastOCRSequence = frame.sequence
                        let snapshot = try await recognizer.recognize(
                            image: frame.image,
                            frameSequence: frame.sequence,
                            geometry: geometry
                        )
                        if let observed = try? makePosition(from: snapshot),
                           PositionVerificationPolicy.matches(observed: observed, expected: expected) {
                            PilotDiagnosticLogger.event(
                                "expected_move_detected_by_ocr move=\(move.ucci) frame=\(frame.sequence)"
                            )
                            return (expected, afterSignature)
                        }
                        if PositionVerificationPolicy.matches(
                            snapshot: snapshot,
                            expected: expected,
                            move: move,
                            orientation: orientation,
                            visualChange: visualChange
                        ) {
                            PilotDiagnosticLogger.event(
                                "expected_move_detected_by_partial_ocr move=\(move.ucci) frame=\(frame.sequence)"
                            )
                            return (expected, afterSignature)
                        }
                    }
                }
            }
            if !announcedSlowTarget,
               startedAt.duration(to: clock.now) >= .seconds(3) {
                announcedSlowTarget = true
                statusMessage = "命令已送达；象棋巫师响应较慢，继续等待并监视棋盘…"
                PilotDiagnosticLogger.event("target_response_exceeded_3_seconds move=\(move.ucci)")
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        PilotDiagnosticLogger.event("target_response_timeout_15_seconds move=\(move.ucci)")
        throw ClickExecutorError.verificationBoardStateUnchanged
    }

    private func applyAnalysis(_ analysis: EngineAnalysis) {
        let legalMoves = Set(game.position.legalMoves)
        let candidates = analysis.candidates.filter { legalMoves.contains($0.move) }.map { candidate -> CandidateMove in
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
        scheduleAutomaticExecutionIfEligible()
    }

    /// Automatic mode is intentionally gated here, after legal-move analysis,
    /// rather than in the view.  This makes the click path identical to a
    /// manually confirmed move and binds it to the exact trusted position.
    private func scheduleAutomaticExecutionIfEligible() {
        guard presentation.controlMode == .automatic,
              !presentation.isPaused,
              !presentation.isEmergencyStopped,
              positionIsTrusted,
              presentation.phase == .previewing else {
            return
        }
        let candidate = presentation.selectedCandidate
        guard candidate.id != CandidateMove.unavailable.id,
              Move(ucci: candidate.id) != nil else {
            return
        }
        let positionKey = game.position.key
        let token = "\(positionKey)|\(candidate.id)"
        guard automaticExecutionToken != token else { return }
        automaticExecutionToken = token
        presentation.recordEvent(
            title: "自动模式已接管",
            detail: "局面校验通过，准备执行 \(candidate.notation)",
            symbolName: "bolt.fill",
            tone: .attention
        )
        Task { [weak self] in
            // Let the published preview settle, then re-check every safety
            // condition immediately before any target-window input.
            await Task.yield()
            guard let self,
                  self.automaticExecutionToken == token,
                  self.presentation.controlMode == .automatic,
                  !self.presentation.isPaused,
                  !self.presentation.isEmergencyStopped,
                  self.positionIsTrusted,
                  self.game.position.key == positionKey,
                  self.presentation.selectedCandidate.id == candidate.id else {
                if self?.automaticExecutionToken == token {
                    self?.automaticExecutionToken = nil
                }
                return
            }
            await self.execute(candidate)
        }
    }

    private func configureIntelligence() async {
        var settings = await settingsStore.load()
        guard (try? apiKeyStore.load(account: AlibabaBailianConfiguration.keychainAccount)) != nil else {
            presentation.modelSource = .off
            return
        }

        let managedIDs: Set<UUID> = [
            AlibabaBailianConfiguration.flashProviderID,
            AlibabaBailianConfiguration.plusProviderID
        ]
        settings.providers.removeAll { managedIDs.contains($0.id) }
        settings.providers.append(contentsOf: [
            AlibabaBailianConfiguration.flash,
            AlibabaBailianConfiguration.plus
        ])
        settings.activeProviderID = AlibabaBailianConfiguration.flashProviderID
        settings.intelligenceMode = .balanced
        settings.allowsCloudImageUpload = true
        try? await settingsStore.save(settings)

        await modelGateway.register(
            OpenAICompatibleProvider(configuration: AlibabaBailianConfiguration.flash),
            activate: true
        )
        await modelGateway.register(
            OpenAICompatibleProvider(configuration: AlibabaBailianConfiguration.plus)
        )
        presentation.modelSource = .cloud
    }

    private func recognizePositionWithAlibabaModel(
        frame: CapturedFrame,
        calibration: BoardCalibration,
        signature: BoardFrameSignature,
        localSnapshot: XiangqiRecognitionSnapshot
    ) async -> Bool {
        guard presentation.modelSource == .cloud,
              let imageBase64 = boardJPEGBase64(
                  image: frame.image,
                  calibration: calibration
              ) else { return false }

        let stateHash = "board-\(frame.contentFingerprint)-\(orientation.rawValue)-\(sideToMove.rawValue)"
        let request = IntelligenceRequest(
            task: .recognizePosition,
            frameSequence: frame.sequence,
            stateHash: stateHash,
            deadlineMilliseconds: 10_000,
            boardImageJPEGBase64: imageBase64,
            context: [
                "orientation": orientation.rawValue,
                "side_to_move": sideToMove == .red ? "red" : "black",
                "local_piece_count": String(localSnapshot.localOccupancy.count),
                "local_confidence": String(format: "%.3f", localSnapshot.confidence),
                "occupied_intersections": localSnapshot.localOccupancy
                    .map { "\($0.file),\($0.rank)" }
                    .sorted()
                    .joined(separator: ";"),
                "instruction": "直接识别全部棋子并输出完整FEN；不要输出思考过程"
            ]
        )

        let attempts: [(id: UUID, label: String, minimumConfidence: Double)] = [
            (AlibabaBailianConfiguration.flashProviderID, "千问3.6 Flash", 0.88),
            (AlibabaBailianConfiguration.plusProviderID, "千问3.7 Plus", 0.88)
        ]
        var modelFailures: [String] = []
        for attempt in attempts {
            statusMessage = "本地识别置信度不足，正在用\(attempt.label)快速复核…"
            do {
                let modelStartedAt = ProcessInfo.processInfo.systemUptime
                let response = try await modelGateway.perform(
                    request,
                    providerID: attempt.id,
                    currentFrameSequence: { request.frameSequence },
                    currentStateHash: { request.stateHash }
                )
                let modelDuration = Int(
                    (ProcessInfo.processInfo.systemUptime - modelStartedAt) * 1_000
                )
                if let usage = response.usage,
                   let billing = await pricingService.billing(
                       modelID: response.modelID ?? attempt.label,
                       usage: usage,
                       durationMilliseconds: modelDuration
                   ) {
                    presentation.recordModelBilling(billing)
                }
                guard response.confidence >= attempt.minimumConfidence else {
                    modelFailures.append("\(attempt.label)置信度\(Int(response.confidence * 100))%")
                    continue
                }
                guard let fen = response.recognizedFEN else {
                    modelFailures.append("\(attempt.label)没有返回FEN")
                    continue
                }
                let position = try ModelRecognizedPositionPolicy.validatedPosition(
                    fen: fen,
                    sideToMove: sideToMove
                )
                let localOccupancy = localSnapshot.localOccupancy
                let modelOccupancy = Set(position.board.placements.map {
                    let visual = visualCoordinate(for: $0.square)
                    return BoardCellCoordinate(file: visual.column, rank: visual.row)
                })
                // The model is specifically a recovery path for OCR misses.
                // Permit it to add a small number of occupied intersections
                // that local OCR failed to classify, but never let it remove a
                // locally observed piece or invent a large part of the board.
                let modelOnlyCells = modelOccupancy.subtracting(localOccupancy)
                let localOnlyCells = localOccupancy.subtracting(modelOccupancy)
                guard localOnlyCells.isEmpty, modelOnlyCells.count <= 3 else {
                    throw XiangqiError.invalidFEN(
                        "模型占位与本地占位冲突：模型\(modelOccupancy.count)枚，本地\(localOccupancy.count)枚"
                    )
                }

                let latest = (try? await capture.latestFrame()) ?? frame
                let latestSignature = boardDifferencer.signature(
                    image: latest.image,
                    frameSequence: latest.sequence,
                    geometry: recognitionGeometry(from: calibration)
                )
                guard boardDifferencer.changes(
                    from: signature,
                    to: latestSignature,
                    minimumScore: 0.07
                ).cells.isEmpty else {
                    recognitionWarnings.append("大模型识别期间棋盘发生变化，已丢弃过期结果")
                    return false
                }

                game.reset(to: position)
                positionIsTrusted = true
                recognizedPieceCount = position.board.pieceCount()
                trustedBoardSignature = latestSignature
                presentation.confidence = response.confidence
                presentation.confidenceBasis = attempt.label
                synchronizePresentation(position: position)
                recognitionWarnings = response.warnings + [
                    "已由\(attempt.label)复核；允许补回\(modelOnlyCells.count)个本地漏检交点，并通过FEN、棋子上限与双将校验"
                ]
                statusMessage = "\(attempt.label)已确认\(recognizedPieceCount)枚局面"
                presentation.recordEvent(
                    title: "云端局面识别可信",
                    detail: "\(attempt.label) · \(recognizedPieceCount)枚 · 置信度\(Int(response.confidence * 100))%",
                    symbolName: "checkmark.seal.fill",
                    tone: .success
                )
                return true
            } catch {
                modelFailures.append("\(attempt.label)：\(error.localizedDescription)")
            }
        }

        recognitionWarnings.append(contentsOf: modelFailures)
        statusMessage = "千问复核未通过安全校验，请人工确认当前局面"
        return false
    }

    private func recognizeRecoveryCandidates(
        frame: CapturedFrame,
        calibration: BoardCalibration,
        signature: BoardFrameSignature,
        localSnapshot: XiangqiRecognitionSnapshot
    ) async -> [RecoveryCandidate] {
        guard presentation.modelSource == .cloud,
              let imageBase64 = boardJPEGBase64(image: frame.image, calibration: calibration) else {
            return []
        }

        let request = IntelligenceRequest(
            task: .recognizePosition,
            frameSequence: frame.sequence,
            stateHash: "recovery-\(frame.contentFingerprint)-\(orientation.rawValue)-\(sideToMove.rawValue)",
            deadlineMilliseconds: 10_000,
            boardImageJPEGBase64: imageBase64,
            context: [
                "orientation": orientation.rawValue,
                "side_to_move": sideToMove == .red ? "red" : "black",
                "local_piece_count": String(localSnapshot.localOccupancy.count),
                "local_confidence": String(format: "%.3f", localSnapshot.confidence),
                "occupied_intersections": localSnapshot.localOccupancy
                    .map { "\($0.file),\($0.rank)" }
                    .sorted()
                    .joined(separator: ";"),
                "instruction": "中盘纠错：只按画面逐格识别全部棋子并输出完整FEN，不补全看不见的棋子，不输出思考过程"
            ]
        )
        let localOccupancy = localSnapshot.localOccupancy
        let attempts: [(UUID, String, PositionRecoverySource)] = [
            (AlibabaBailianConfiguration.flashProviderID, "千问3.6 Flash", .qwenFlash),
            (AlibabaBailianConfiguration.plusProviderID, "千问3.7 Plus", .qwenPlus)
        ]
        var candidates: [RecoveryCandidate] = []
        var failures: [String] = []

        for (providerID, label, source) in attempts {
            statusMessage = "正在用\(label)复核中盘局面…"
            presentation.recoveryProgressText = "\(label)复核中（有硬性超时）"
            do {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let response = try await performRecoveryModelRequest(
                    request: request,
                    providerID: providerID,
                    label: label,
                    timeout: source == .qwenFlash ? .seconds(5) : .seconds(6)
                )
                let duration = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
                if let usage = response.usage,
                   let billing = await pricingService.billing(
                       modelID: response.modelID ?? label,
                       usage: usage,
                       durationMilliseconds: duration
                   ) {
                    presentation.recordModelBilling(billing)
                }
                guard response.confidence >= 0.88,
                      let fen = response.recognizedFEN else {
                    failures.append("\(label)未达到88%或未返回FEN")
                    continue
                }
                let position = try ModelRecognizedPositionPolicy.validatedPosition(
                    fen: fen,
                    sideToMove: sideToMove
                )
                let occupancy = Set(position.board.placements.map {
                    let visual = visualCoordinate(for: $0.square)
                    return BoardCellCoordinate(file: visual.column, rank: visual.row)
                })
                let modelOnlyCells = occupancy.subtracting(localOccupancy)
                let localOnlyCells = localOccupancy.subtracting(occupancy)
                guard localOnlyCells.isEmpty, modelOnlyCells.count <= 3 else {
                    failures.append("\(label)占位与本地检测冲突")
                    continue
                }
                let latest = (try? await capture.latestFrame()) ?? frame
                let latestSignature = boardDifferencer.signature(
                    image: latest.image,
                    frameSequence: latest.sequence,
                    geometry: recognitionGeometry(from: calibration)
                )
                guard boardDifferencer.changes(
                    from: signature,
                    to: latestSignature,
                    minimumScore: 0.07
                ).cells.isEmpty else {
                    failures.append("\(label)识别期间画面已变化")
                    break
                }
                candidates.append(RecoveryCandidate(
                    position: position,
                    signature: latestSignature,
                    confidence: response.confidence,
                    source: source,
                    canAutoApply: false
                ))
                // Fast path: local OCR and Flash are already independent
                // evidence. Plus is reserved for disagreement or incomplete
                // local classification, reducing both latency and cost.
                if source == .qwenFlash,
                   localSnapshot.confidence >= 0.88,
                   let localPosition = try? makePosition(from: localSnapshot),
                   localPosition.board == position.board {
                    break
                }
            } catch {
                failures.append("\(label)：\(error.localizedDescription)")
            }
        }
        recognitionWarnings = localSnapshot.warnings + failures
        return candidates
    }

    private func performRecoveryModelRequest(
        request: IntelligenceRequest,
        providerID: UUID,
        label: String,
        timeout: Duration
    ) async throws -> IntelligenceResponse {
        let gateway = modelGateway
        return try await withThrowingTaskGroup(of: IntelligenceResponse.self) { group in
            group.addTask {
                try await gateway.perform(
                    request,
                    providerID: providerID,
                    currentFrameSequence: { request.frameSequence },
                    currentStateHash: { request.stateHash }
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RecoveryTimeoutError.model(label)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RecoveryTimeoutError.model(label)
            }
            return first
        }
    }

    private func publishRecoveryCandidate(_ candidate: RecoveryCandidate) {
        let oldPieces = boardPieces(for: lastTrustedPosition ?? game.position)
        let newPieces = boardPieces(for: candidate.position)
        let oldByCoordinate = Dictionary(uniqueKeysWithValues: oldPieces.map { ($0.coordinate, $0) })
        let newByCoordinate = Dictionary(uniqueKeysWithValues: newPieces.map { ($0.coordinate, $0) })
        let coordinates = Set(oldByCoordinate.keys).union(newByCoordinate.keys)
        let differences = coordinates.compactMap { coordinate -> PositionRecoveryDifference? in
            let old = oldByCoordinate[coordinate]
            let new = newByCoordinate[coordinate]
            guard old?.side != new?.side || old?.character != new?.character else { return nil }
            return PositionRecoveryDifference(
                coordinate: coordinate,
                trustedPiece: old,
                observedPiece: new
            )
        }.sorted {
            ($0.coordinate.row, $0.coordinate.column) < ($1.coordinate.row, $1.coordinate.column)
        }

        presentation.recoveryCandidatePieces = newPieces
        presentation.recoveryCandidateSideToMove = candidate.position.sideToMove == .red ? .red : .black
        presentation.recoveryCandidatePieceCount = candidate.position.board.pieceCount()
        presentation.recoveryDifferences = differences
        presentation.recoveryConfidence = candidate.confidence
        presentation.recoverySource = candidate.source
        presentation.recoveryCanAutoApply = candidate.canAutoApply
        presentation.recoveryHasCandidate = true
    }

    private func boardPieces(for position: Position) -> [BoardPiece] {
        position.board.placements.map { placement in
            let coordinate = visualCoordinate(for: placement.square)
            return BoardPiece(
                side: placement.piece.side == .red ? .red : .black,
                character: glyph(for: placement.piece),
                column: coordinate.column,
                row: coordinate.row
            )
        }
    }

    private func boardJPEGBase64(
        image: CGImage,
        calibration: BoardCalibration
    ) -> String? {
        let xs = [
            calibration.corners.topLeft.x, calibration.corners.topRight.x,
            calibration.corners.bottomLeft.x, calibration.corners.bottomRight.x
        ]
        let ys = [
            calibration.corners.topLeft.y, calibration.corners.topRight.y,
            calibration.corners.bottomLeft.y, calibration.corners.bottomRight.y
        ]
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let horizontalPadding = (maxX - minX) / 16
        let verticalPadding = (maxY - minY) / 18
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = CGRect(
            x: minX - horizontalPadding,
            y: minY - verticalPadding,
            width: maxX - minX + horizontalPadding * 2,
            height: maxY - minY + verticalPadding * 2
        ).intersection(bounds).integral
        guard cropRect.width > 10, cropRect.height > 10,
              let cropped = image.cropping(to: cropRect) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cropped)
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        )?.base64EncodedString()
    }

    private func synchronizePresentation(position: Position) {
        if positionIsTrusted {
            lastTrustedPosition = position
        }
        presentation.sideToMove = position.sideToMove == .red ? .red : .black
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

    private static func pikafishExecutableURL() -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Engines", isDirectory: true)
            .appendingPathComponent("pikafish", isDirectory: false)
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/Pikafish/pikafish", isDirectory: false)
        return [bundled, development]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? bundled
            ?? development
    }

    private static func cornerPreset(for bundleIdentifier: String?) -> NormalizedBoardCorners? {
        guard bundleIdentifier == "com.jpcxc.xqwiphone" else { return nil }
        // 象棋巫师的棋盘在窗口左侧，右侧是对局信息栏。
        return NormalizedBoardCorners(
            topLeft: CGPoint(x: 0.086, y: 0.165),
            topRight: CGPoint(x: 0.607, y: 0.165),
            bottomLeft: CGPoint(x: 0.086, y: 0.902),
            bottomRight: CGPoint(x: 0.607, y: 0.902)
        )
    }

    private static func savedCorners(for bundleIdentifier: String?) -> NormalizedBoardCorners? {
        guard let bundleIdentifier else { return nil }
        let values = UserDefaults.standard.array(
            forKey: "boardCorners.\(bundleIdentifier)"
        ) as? [Double]
        guard let values, values.count == 8 else { return nil }
        return NormalizedBoardCorners(
            topLeft: CGPoint(x: values[0], y: values[1]),
            topRight: CGPoint(x: values[2], y: values[3]),
            bottomLeft: CGPoint(x: values[4], y: values[5]),
            bottomRight: CGPoint(x: values[6], y: values[7])
        )
    }

    private static func saveCorners(
        _ corners: NormalizedBoardCorners,
        for bundleIdentifier: String?
    ) {
        guard let bundleIdentifier else { return }
        UserDefaults.standard.set([
            Double(corners.topLeft.x), Double(corners.topLeft.y),
            Double(corners.topRight.x), Double(corners.topRight.y),
            Double(corners.bottomLeft.x), Double(corners.bottomLeft.y),
            Double(corners.bottomRight.x), Double(corners.bottomRight.y)
        ], forKey: "boardCorners.\(bundleIdentifier)")
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
        reconcileTrustedPosition(from: frame)
    }

    /// Keeps the rule-backed digital board synchronized with moves made by the
    /// target program or the user. Pixel changes are never copied directly:
    /// exactly one legal move must explain the two changed intersections.
    private func reconcileTrustedPosition(from frame: CapturedFrame) {
        guard setupStep == .ready,
              positionIsTrusted,
              frame.sequence > lastReconciledFrameSequence,
              let calibration,
              let trustedBoardSignature else { return }
        switch presentation.phase {
        case .acting, .verifying, .recognizing:
            return
        case .observing, .thinking, .previewing:
            break
        }
        lastReconciledFrameSequence = frame.sequence

        let signature = boardDifferencer.signature(
            image: frame.image,
            frameSequence: frame.sequence,
            geometry: recognitionGeometry(from: calibration)
        )
        let visualChange = boardDifferencer.changes(
            from: trustedBoardSignature,
            to: signature,
            minimumScore: 0.07
        )
        switch RecognitionTransitionPolicy.decide(
            trusted: game.position,
            orientation: orientation,
            visualChange: visualChange
        ) {
        case .unchanged:
            self.trustedBoardSignature = signature
            rejectedChangeKey = nil
            rejectedChangeFirstSeenAt = nil
            recoveredOrAttemptedChangeKey = nil
        case .legalMove(let move):
            let before = game.position
            do {
                analysisTask?.cancel()
                _ = try game.play(move)
                sideToMove = game.position.sideToMove
                self.trustedBoardSignature = signature
                rejectedChangeKey = nil
                rejectedChangeFirstSeenAt = nil
                recoveredOrAttemptedChangeKey = nil
                presentation.confidence = 1
                presentation.confidenceBasis = "合法着法差分"
                synchronizePresentation(position: game.position)
                statusMessage = "数字棋盘已实时同步：\(move.ucci)"
                Task { [weak self] in
                    guard let self else { return }
                    await self.recordObservedMove(move, before: before, after: self.game.position)
                    await self.analyzeCurrentPosition()
                }
            } catch {
                blockingError = "实时棋盘同步失败：\(error.localizedDescription)"
            }
        case .rejected:
            // Highlights and animations are usually brief. Only a stable,
            // repeated unexplained pattern enters recovery, so one transient
            // frame can never invoke AI or replace the trusted board.
            let key = visualChange.cells
                .map { "\($0.coordinate.file),\($0.coordinate.rank)" }
                .sorted()
                .joined(separator: ";")
            let now = ProcessInfo.processInfo.systemUptime
            if rejectedChangeKey != key {
                rejectedChangeKey = key
                rejectedChangeFirstSeenAt = now
                recoveredOrAttemptedChangeKey = nil
                return
            }
            guard let firstSeen = rejectedChangeFirstSeenAt,
                  now - firstSeen >= 0.45,
                  recoveredOrAttemptedChangeKey != key,
                  recoveryTask == nil else { return }
            presentation.recoveryReason = "棋盘变化持续超过450毫秒，无法用唯一一步合法走棋解释"
            presentation.recoveryDetectedAt = Date()
            presentation.recoveryNeedsAttention = true
            presentation.recordEvent(
                title: "检测到中盘局面异常",
                detail: "\(visualChange.cells.count)个交点变化无法用一步合法棋解释，已暂停自动点击",
                symbolName: "exclamationmark.shield.fill",
                tone: .danger
            )
            recoveredOrAttemptedChangeKey = key
            recoveryTask = Task { [weak self] in
                await self?.beginPositionRecovery()
            }
        }
    }

    private func wirePresentationActions() {
        presentation.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            Task { @MainActor in
                if paused {
                    await self.clickExecutor.pause(.userRequested)
                } else {
                    do {
                        try await self.clickExecutor.arm()
                        self.blockingError = nil
                        self.statusMessage = "已恢复控制，执行前将重新校验棋盘"
                        // The user may choose automatic mode while paused.
                        // Resuming is therefore a new eligibility edge and
                        // must re-queue the already analysed candidate.
                        self.scheduleAutomaticExecutionIfEligible()
                    } catch {
                        self.pause(reason: PilotDiagnostic(error: error).displayText)
                    }
                }
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
        presentation.onControlModeChanged = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleAutomaticExecutionIfEligible() }
        }
        presentation.onRecover = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.applyRecoveryCandidate() }
        }
        presentation.onBeginRecovery = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.beginPositionRecovery(reason: "用户主动请求重新识别当前中盘局面") }
        }
        presentation.onApplyRecoveryCandidate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.applyRecoveryCandidate() }
        }
        presentation.onDiscardRecoveryCandidate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.discardRecoveryCandidate() }
        }
        presentation.onEngineSourceChanged = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.analyzeCurrentPosition() }
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

    private func recordObservedMove(_ move: Move, before: Position, after: Position) async {
        presentation.recordEvent(
            title: "检测到棋盘实时变化",
            detail: "\(move.ucci) · 当前\(after.board.pieceCount())枚 · \(after.sideToMove == .red ? "红方" : "黑方")走",
            symbolName: "eye.fill",
            tone: .success
        )
        guard var current = session else { return }
        current.currentFEN = after.fen
        current.moves.append(SessionMoveRecord(
            ply: current.moves.count + 1,
            fenBefore: before.fen,
            move: move.ucci,
            fenAfter: after.fen,
            source: .human,
            confidence: presentation.confidence,
            thinkingMilliseconds: 0,
            outcome: .executed,
            note: "由可信棋盘的一步合法视觉变化确认"
        ))
        session = current
        try? await sessionStore.save(current)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
