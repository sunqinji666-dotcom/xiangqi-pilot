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

    static func preset(for bundleIdentifier: String?) -> BoardOrientation? {
        guard let bundleIdentifier else { return nil }
        if bundleIdentifier == "com.cronlygames.chschess.mac" { return .redAtTop }
        return nil
    }
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

        // OCR/template matching may hallucinate a moved piece back onto its
        // familiar opening square. Occupancy is measured independently from
        // glyph recognition, so an automatic standard-position recovery is
        // safe only when every one of the 32 physical piece bodies occupies
        // the exact opening intersection. Count alone is not sufficient.
        guard snapshot.localOccupancy == Set(expected.keys) else { return false }

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

private struct PendingObservedMove {
    let move: Move
    let firstSeenAt: TimeInterval
    var lastSeenAt: TimeInterval
}

private struct VerifiedMoveSequence {
    let position: Position
    let signature: BoardFrameSignature
    let opponentReply: Move?
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
    @Published var xiangqiControlledSide: Side = .red
    @Published var gridControlledSide: GridStone = .black
    @Published var gridControlsBothSides = false
    @Published var gridSideToMove: GridStone = .black
    @Published var tencentPaidMatchConfirmationPending = false
    @Published var detectedGridTerminal: GridTerminalResult?
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
    private let gridState = GridGameRuntimeState()
    private let gridTargetBootstrapper = GridTargetBootstrapper()
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
    /// Calibration is normally shared by application bundle. A browser can
    /// host unrelated board sites with completely different layouts, so known
    /// web adapters receive their own stable preference key.
    private var selectedCalibrationKey: String?
    private var lastReconciledFrameSequence: UInt64 = 0
    private var lastGridReconciledFrameSequence: UInt64 = 0
    private var lastGridRecognitionAt: TimeInterval = 0
    private var lastGridTerminalRecognitionAt: TimeInterval = 0
    private var lastGridTerminalResult: GridTerminalResult?
    /// An explicit cockpit-concede request is not evidence by itself. It only
    /// supplies the expected result once the locked client visibly presents a
    /// terminal overlay, including clients that draw the result glyph rather
    /// than OCR-friendly text.
    private var pendingConcededGridTerminal: GridTerminalResult?
    /// A local-client reset may intentionally pass through a “失败/认输” page
    /// before it opens a fresh board.  That is bootstrap plumbing, not the
    /// terminal result of the game the cockpit is about to monitor.
    private var gridBootstrapInProgress = false
    /// A target window can briefly redraw a board while changing focus or
    /// finishing an animation.  Never pause on a single noisy recognition;
    /// require the same unexplained position in consecutive stable samples.
    private var pendingGridUnexplainedObservation: [GridCoordinate: GridStone]?
    private var pendingGridUnexplainedCount = 0
    /// Local mobile-board clients repaint the last-move badge over several
    /// frames after a verified grid click. During this short interval, colour
    /// samples may temporarily disagree with the already-proven rule state.
    private var lastAcceptedGridMoveAt: TimeInterval?
    /// The exact intersection that was proved by the cockpit click receipt.
    /// Tencent Go can render its last-move badge as an apparent empty or dark
    /// point, so this one point is held as a visual stability anchor.
    private var lastAcceptedGridCoordinate: GridCoordinate?
    /// A candidate may be published repeatedly while SwiftUI redraws.  Keep one
    /// pending automatic dispatch per exact board position so automatic mode
    /// cannot send duplicate clicks for the same move.
    private var automaticExecutionToken: String?
    /// Explicit terminal actions have priority over automatic play. It closes
    /// the short scheduling window between a visible preview and its queued
    /// target-window click.
    private var concedingGridGame = false
    /// Serializes every manual and automatic entry into the GUI action path.
    /// Main-actor async methods are re-entrant, so without this guard a second
    /// confirmation can arm the executor while the first one is activating the
    /// target window and invalidate its safety epoch.
    private var executionInProgress = false
    private var pendingObservedMove: PendingObservedMove?
    /// Used only to suppress the one-cell selection/last-move decoration that
    /// 象棋巫师 removes shortly after a legal move has already been accepted.
    /// It never authorizes a chess-state change.
    private var lastAcceptedVisualMoveAt: TimeInterval?
    private var lastWizardMoveOCRAttemptAt: TimeInterval = 0
    private var lastWizardTerminalResult: XiangqiWizardTerminalResult?
    /// A deterministic terminal position may be observed repeatedly by the
    /// capture loop. Record it once so the timeline remains a real audit log.
    private var lastRuleTerminalPositionKey: PositionKey?
    /// Measured from the moment the current trusted position is sent to an
    /// engine until its candidate is published.  Persisted with executed moves
    /// so performance regressions are visible in the review timeline.
    private var lastAnalysisDurationMilliseconds = 0
    private var game = Game()
    private var session: XiangqiSessionRecord?
    private var restoredSessionForSetup: XiangqiSessionRecord?

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
        // Keep the first actual move responsive.  The client is idempotent and
        // falls back to the local engine if the bundled binary is unavailable.
        Task { [pikafishEngine] in
            try? await pikafishEngine.start()
        }
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
            let windows = try await capture.refreshAvailableWindows()
                .filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
            availableWindows = windows.filter(matchesSelectedGameTarget)
            statusMessage = availableWindows.isEmpty
                ? "没有找到可捕获窗口"
                : "找到 \(availableWindows.count) 个可选窗口"
        } catch {
            blockingError = error.localizedDescription
        }
    }

    private func matchesSelectedGameTarget(_ window: CapturableWindow) -> Bool {
        switch presentation.selectedGame {
        case .xiangqi:
            return true
        case .gomoku:
            return window.bundleIdentifier == "com.sining.wuziqi"
                || window.applicationName.localizedCaseInsensitiveContains("五子棋")
        case .go:
            return window.bundleIdentifier == "com.tencent.TtgoForIos"
                || window.applicationName.localizedCaseInsensitiveContains("腾讯围棋")
        }
    }

    private func changeGameKind(_ gameKind: GameKind) async {
        analysisTask?.cancel()
        recoveryTask?.cancel()
        await clickExecutor.pause(.manualTakeover)
        await gridState.clickExecutor.pause()
        calibration = nil
        gridState.reset()
        detectedGridTerminal = nil
        lastGridTerminalResult = nil
        lastGridTerminalRecognitionAt = 0
        latestCapturedFrame = nil
        trustedBoardSignature = nil
        lastReconciledFrameSequence = 0
        lastGridReconciledFrameSequence = 0
        pendingGridUnexplainedObservation = nil
        pendingGridUnexplainedCount = 0
        lastAcceptedGridMoveAt = nil
        lastAcceptedGridCoordinate = nil
        pendingConcededGridTerminal = nil
        positionIsTrusted = false
        recognizedPieceCount = 0
        presentation.pieces = []
        presentation.gridStones = []
        presentation.gridLineCount = gameKind.gridLineCount
        presentation.gridSideToMove = .black
        presentation.candidates = [.unavailable]
        presentation.selectedCandidateID = CandidateMove.unavailable.id
        presentation.sideToMove = .red
        xiangqiControlledSide = .red
        presentation.isPaused = true
        presentation.phase = .observing
        presentation.source = WindowSource(
            id: "unselected",
            applicationName: "尚未选择窗口",
            windowTitle: "请选择\(gameKind.title)窗口",
            isLocked: false
        )
        setupStep = .window
        statusMessage = "请选择正在运行的\(gameKind.title)窗口"
        await refreshWindows()
    }

    func selectWindow(_ window: CapturableWindow) async {
        isBusy = true
        blockingError = nil
        lastWizardTerminalResult = nil
        detectedGridTerminal = nil
        lastGridTerminalResult = nil
        lastGridTerminalRecognitionAt = 0
        do {
            let target = try await capture.lockWindow(window.windowID)
            selectedBundleIdentifier = window.bundleIdentifier
            if presentation.selectedGame == .xiangqi,
               let preset = BoardOrientation.preset(for: window.bundleIdentifier) {
                orientation = preset
                xiangqiControlledSide = preset == .redAtTop ? .black : .red
            }
            selectedCalibrationKey = Self.calibrationKey(
                bundleIdentifier: window.bundleIdentifier,
                windowTitle: target.title
            )
            normalizedCorners = Self.savedCorners(for: selectedCalibrationKey)
                ?? Self.gridCornerPreset(
                    for: presentation.selectedGame,
                    bundleIdentifier: window.bundleIdentifier
                )
                ?? Self.cornerPreset(
                    for: window.bundleIdentifier,
                    windowTitle: target.title
                )
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

    func startSelectedGridGame() async {
        await startSelectedGridGame(authorizingTencentPaidMatch: false)
    }

    /// The second confirmation lives in the cockpit UI and is intentionally
    /// ephemeral: it authorizes only the currently visible Tencent Go cost
    /// dialog, never future matches or arbitrary client controls.
    func confirmTencentPaidMatchAndStart() async {
        guard presentation.selectedGame == .go,
              tencentPaidMatchConfirmationPending else { return }
        await startSelectedGridGame(authorizingTencentPaidMatch: true)
    }

    private func startSelectedGridGame(authorizingTencentPaidMatch: Bool) async {
        guard presentation.selectedGame != .xiangqi else { return }
        isBusy = true
        gridBootstrapInProgress = true
        // Do not let a terminal label observed during the old-game cleanup
        // carry into the fresh session after the launcher completes.
        detectedGridTerminal = nil
        lastGridTerminalResult = nil
        defer {
            isBusy = false
            gridBootstrapInProgress = false
            lastGridTerminalResult = nil
        }
        do {
            let stage = gridState.bootstrapStage
            statusMessage = "驾驶舱正在请求启动本机\(presentation.selectedGame.title)对局…"
            try await gridTargetBootstrapper.advanceLocalAI(
                game: presentation.selectedGame,
                stage: stage,
                capture: capture,
                authorizingTencentPaidMatch: authorizingTencentPaidMatch
            )
            tencentPaidMatchConfirmationPending = false
            gridState.bootstrapStage += 1
            statusMessage = presentation.selectedGame == .gomoku && stage == 0
                ? "已打开难度页；请点击“选择入门难度并开始”"
                : "本机对局入口已打开，请在下方标定真实棋盘四角"
            presentation.recordEvent(
                title: "已启动本机人机入口",
                detail: "\(presentation.selectedGame.title)目标窗口已由驾驶舱操作（步骤\(stage + 1)）",
                symbolName: "play.circle.fill",
                tone: .success
            )
        } catch GridTargetBootstrapError.paidConfirmationRequired {
            tencentPaidMatchConfirmationPending = true
            blockingError = GridTargetBootstrapError.paidConfirmationRequired.localizedDescription
        } catch {
            blockingError = error.localizedDescription
        }
    }

    func concedeCurrentGridGame() async {
        guard presentation.selectedGame == .go else {
            blockingError = "当前仅支持通过驾驶舱结束腾讯围棋局"
            return
        }
        guard setupStep == .ready, positionIsTrusted else {
            blockingError = "请先完成围棋局面确认后再结束本局"
            return
        }
        guard !executionInProgress else {
            blockingError = "当前自动落子正在验证，请等待本手完成后再结束本局"
            return
        }
        concedingGridGame = true
        automaticExecutionToken = nil
        presentation.isPaused = true
        isBusy = true
        presentation.phase = .acting
        defer { isBusy = false }
        do {
            pendingConcededGridTerminal = .loss
            try await gridTargetBootstrapper.concedeCurrentGo(capture: capture)
            pendingConcededGridTerminal = nil
            lastGridTerminalResult = .loss
            detectedGridTerminal = .loss
            finishGridGame("腾讯围棋客户端终局：失败（驾驶舱确认认输并验证画面回执）")
            presentation.recordEvent(
                title: "腾讯围棋终局已验证",
                detail: "驾驶舱确认认输后，锁定客户端窗口已产生终局画面回执",
                symbolName: "flag.fill",
                tone: .success
            )
        } catch {
            pendingConcededGridTerminal = nil
            concedingGridGame = false
            presentation.phase = .observing
            blockingError = error.localizedDescription
        }
    }

    var selectedGridBootstrapTitle: String {
        if presentation.selectedGame == .gomoku, gridState.bootstrapStage == 1 {
            return "选择入门难度并开始"
        }
        return "启动本机人机对局"
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
            if let lineCount = presentation.selectedGame.gridLineCount {
                gridState.calibration = try GridBoardCalibration(
                    corners: corners,
                    imageSize: size,
                    windowFrame: liveWindow.frame,
                    lineCount: lineCount
                )
                Self.saveCorners(normalizedCorners, for: selectedCalibrationKey)
                setupStep = .position
                statusMessage = "正在识别\(presentation.selectedGame.title)局面…"
                await recognizeGridPosition()
                return
            }
            calibration = try BoardCalibration(
                corners: corners,
                imageSize: size,
                windowFrame: liveWindow.frame
            )
            Self.saveCorners(normalizedCorners, for: selectedCalibrationKey)
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
            if XiangqiWebMoveLogReader.matches(
                bundleIdentifier: selectedBundleIdentifier,
                windowTitle: frame.target.title
            ) {
                guard let replay = XiangqiWebMoveLogReader.replayedPosition(
                    ownerPID: frame.target.ownerPID
                ) else {
                    throw XiangqiError.invalidFEN("网页走棋记录无法解析")
                }
                game.reset(to: .standard)
                for move in replay.moves {
                    _ = try game.play(move)
                }
                sideToMove = replay.position.sideToMove
                positionIsTrusted = true
                recognizedPieceCount = replay.position.board.pieceCount()
                recognitionWarnings = []
                presentation.confidence = 1
                presentation.confidenceBasis = "网页官方走棋记录＋本地棋规"
                trustedBoardSignature = boardDifferencer.signature(
                    image: frame.image,
                    frameSequence: frame.sequence,
                    geometry: recognitionGeometry(from: calibration)
                )
                synchronizePresentation(position: replay.position)
                statusMessage = replay.moves.isEmpty
                    ? "已通过网页官方记录确认标准开局"
                    : "已通过网页官方记录同步\(replay.moves.count)个半回合"
                presentation.recordEvent(
                    title: "网页局面已可信同步",
                    detail: "\(replay.moves.count)个半回合 · 官方记录＋本地棋规",
                    symbolName: "checkmark.seal.fill",
                    tone: .success
                )
                await analyzeCurrentPosition()
                return
            }
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
                geometry: geometry,
                targetBundleIdentifier: selectedBundleIdentifier
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
            // Do not throw away a useful partial recognition merely because it
            // is not yet a legal Xiangqi position (for example, one general
            // was obscured by an animation).  Keeping this draft on the
            // digital board makes the discrepancy visible and lets the user
            // correct only the bad cells instead of starting from an empty
            // board.
            if let snapshot = try? await recognizer.recognize(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: recognitionGeometry(from: calibration),
                targetBundleIdentifier: selectedBundleIdentifier
            ) {
                recognizedPieceCount = snapshot.localOccupancy.count
                recognitionWarnings = snapshot.warnings
                recognitionWarnings.append("无法建立合法局面：\(error.localizedDescription)")
                recognitionWarnings.append(recognitionDraftSummary(snapshot))
                synchronizeRecognitionDraft(snapshot)
            } else {
                recognitionWarnings = ["无法建立合法局面：\(error.localizedDescription)"]
            }
            blockingError = "局面识别需要人工确认：\(error.localizedDescription)"
            presentation.confidence = 0
            presentation.confidenceBasis = "识别失败"
            presentation.phase = .observing
            presentation.recordEvent(
                title: "局面识别待校正",
                detail: "保留已识别棋子草稿；请核对标黄位置",
                symbolName: "exclamationmark.triangle.fill",
                tone: .attention
            )
        }
    }

    /// Recognition path for a 15×15 Gomoku or 19-line Go board.  It relies on
    /// calibrated stone discs, then asks the rules core to reject impossible
    /// colour counts before the digital board becomes trusted.
    func recognizeGridPosition() async {
        guard let frame = latestCapturedFrame,
              let calibration = gridState.calibration,
              let lineCount = presentation.selectedGame.gridLineCount else {
            blockingError = "请先完成交点棋盘标定"
            return
        }
        isBusy = true
        presentation.phase = .recognizing
        defer { isBusy = false }
        // A result card is not an empty board.  This guard is deliberately
        // before colour sampling so a completed game can never establish a
        // fresh trusted baseline merely because its artwork happens to look
        // empty at the calibrated intersections.
        if finishGridGameIfTerminalVisible(in: frame) {
            return
        }
        let snapshot = GridStoneRecognizer.recognize(image: frame.image, calibration: calibration)
        let stones = snapshot.stones
        let isFirstGridRecognition = gridState.lastObservedStones.isEmpty
            && gridState.gomokuPosition == nil
            && gridState.goPosition == nil
        let trusted: Bool
        switch presentation.selectedGame {
        case .gomoku:
            guard let position = GridGameTransitionPolicy.initialGomokuPosition(size: lineCount, stones: stones) else {
                blockingError = "五子棋颜色或手数不符合合法轮次，请检查四角标定"
                presentation.confidence = snapshot.confidence
                return
            }
            gridState.gomokuPosition = position
            gridState.goPosition = nil
            gridSideToMove = position.sideToMove
            trusted = true
        case .go:
            guard let position = GridGameTransitionPolicy.initialGoPosition(size: lineCount, stones: stones) else {
                blockingError = "围棋颜色或让子数量不符合规则，请检查四角标定"
                presentation.confidence = snapshot.confidence
                return
            }
            gridState.goPosition = position
            gridState.gomokuPosition = nil
            gridSideToMove = position.sideToMove
            trusted = true
        case .xiangqi:
            return
        }
        gridState.lastObservedStones = stones
        // Local AI clients commonly make the opening move before the cockpit
        // finishes calibration.  On a newly locked board, default control to
        // the side that is actually due to move, so automatic mode can begin
        // immediately rather than silently waiting for the already-acted side.
        if isFirstGridRecognition {
            gridControlledSide = gridSideToMove
        }
        synchronizeGridPresentation(stones: stones, lineCount: lineCount)
        positionIsTrusted = trusted
        recognizedPieceCount = stones.count
        presentation.confidence = snapshot.confidence
        presentation.confidenceBasis = "本地交点色彩识别＋规则校验"
        blockingError = nil
        statusMessage = "已识别\(stones.count)枚\(presentation.selectedGame.title)棋子，请确认执棋方后进入驾驶舱"
        presentation.recordEvent(
            title: "交点棋局已识别",
            detail: "\(stones.count)枚 · \(presentation.selectedGame.title) · 本地色彩识别＋规则校验",
            symbolName: "checkmark.seal.fill",
            tone: .success
        )
    }

    private func synchronizeGridPresentation(stones: [GridCoordinate: GridStone], lineCount: Int) {
        presentation.gridLineCount = lineCount
        presentation.gridStones = stones.map { GridStonePiece(side: $0.value, coordinate: $0.key) }
            .sorted { $0.coordinate < $1.coordinate }
        presentation.gridSideToMove = gridSideToMove
        presentation.pieces = []
        presentation.candidates = [.unavailable]
        presentation.selectedCandidateID = CandidateMove.unavailable.id
    }

    /// Shows the recognizer's best-effort board without pretending it is
    /// trusted. Unknown-side pieces are intentionally omitted: presenting a
    /// fabricated red/black side is more dangerous than leaving one cell for
    /// the correction sheet.
    private func synchronizeRecognitionDraft(_ snapshot: XiangqiRecognitionSnapshot) {
        presentation.pieces = snapshot.pieces.compactMap { recognized in
            guard recognized.side != .unknown else { return nil }
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
            return BoardPiece(
                side: recognized.side == .red ? .red : .black,
                character: glyph(for: Piece(side: side, kind: kind)),
                column: recognized.file,
                row: recognized.rank
            )
        }
    }

    private func recognitionDraftSummary(_ snapshot: XiangqiRecognitionSnapshot) -> String {
        let unknownSides = snapshot.pieces.filter { $0.side == .unknown }.count
        let red = snapshot.pieces.filter { $0.side == .red }.count
        let black = snapshot.pieces.filter { $0.side == .black }.count
        return "识别草稿：占位\(snapshot.localOccupancy.count)格，已分类红\(red)黑\(black)，颜色待定\(unknownSides)"
    }

    func useStandardPositionForCorrection() async {
        restoredSessionForSetup = nil
        game.reset(to: .standard)
        recognitionWarnings = ["已载入标准局面，请根据画面修正"]
        recognizedPieceCount = 32
        presentation.confidence = 1
        presentation.confidenceBasis = "待人工确认"
        positionIsTrusted = false
        synchronizePresentation(position: game.position)
        await analyzeCurrentPosition()
    }

    /// Restores the last persisted, rule-valid position for the selected target
    /// as an explicit correction draft. The user still confirms it against the
    /// visible board before automation is armed.
    func restoreLatestSessionForCorrection() async {
        do {
            let sessions = try await sessionStore.list()
            guard let latest = sessions.first(where: { record in
                record.targetApplicationName == presentation.source.applicationName
                    || record.targetWindowTitle == presentation.source.windowTitle
            }) else {
                blockingError = "没有找到这个目标程序的历史可信局面"
                return
            }
            let position = try Position(fen: latest.currentFEN)
            game.reset(to: position)
            restoredSessionForSetup = latest
            sideToMove = position.sideToMove
            recognizedPieceCount = position.board.pieceCount()
            positionIsTrusted = false
            presentation.confidence = 1
            presentation.confidenceBasis = "上次已验证局面（等待画面对照确认）"
            synchronizePresentation(position: position)
            recognitionWarnings = [
                "已恢复上次可信记录：\(latest.moves.count)手，更新时间\(latest.updatedAt.formatted(date: .omitted, time: .standard))；请与真实棋盘核对后确认。"
            ]
            blockingError = nil
            statusMessage = "已载入上次可信局面，等待确认"
        } catch {
            blockingError = "恢复上次棋局失败：\(error.localizedDescription)"
        }
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
            lastWizardTerminalResult = nil
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

        let shouldResumeAfterLocalRecovery = !presentation.isPaused && !presentation.isEmergencyStopped
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

            // Level 1: a stable local delta can explain either one move, or
            // two consecutive plies when the opponent replied before the
            // polling loop saw the intermediate frame.  Both paths avoid OCR
            // and cloud latency completely.
            if let trustedBoardSignature {
                let visualChange = boardDifferencer.changes(
                    from: trustedBoardSignature,
                    to: signature,
                    minimumScore: 0.07
                )
                if let line = RecognitionTransitionPolicy.decoratedLegalLine(
                    trusted: game.position,
                    orientation: orientation,
                    visualChange: visualChange
                ) {
                    try await applyStableLocalRecovery(
                        moves: line,
                        signature: signature,
                        resumeAutomation: shouldResumeAfterLocalRecovery
                    )
                    return
                }
                if let move = RecognitionTransitionPolicy.decoratedLegalMove(
                    trusted: game.position,
                    orientation: orientation,
                    visualChange: visualChange
                ) {
                    try await applyStableLocalRecovery(
                        moves: [move],
                        signature: signature,
                        resumeAutomation: shouldResumeAfterLocalRecovery
                    )
                    return
                }
            }

            presentation.recoveryProgressText = "本地视觉正在识别90个交点"
            let snapshot = try await recognizer.recognize(
                image: frame.image,
                frameSequence: frame.sequence,
                geometry: geometry,
                targetBundleIdentifier: selectedBundleIdentifier
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

    /// Applies an already-stable, uniquely explained visual transition.  No
    /// OCR or cloud call is involved, and the old trusted board is never
    /// overwritten by an unclassified image.
    private func applyStableLocalRecovery(
        moves: [Move],
        signature: BoardFrameSignature,
        resumeAutomation: Bool
    ) async throws {
        guard !moves.isEmpty else { return }
        var recovered: [(move: Move, before: Position, after: Position)] = []
        for move in moves {
            let before = game.position
            _ = try game.play(move)
            recovered.append((move, before, game.position))
        }
        sideToMove = game.position.sideToMove
        trustedBoardSignature = signature
        lastReconciledFrameSequence = signature.frameSequence
        lastTrustedPosition = game.position
        positionIsTrusted = true
        recognizedPieceCount = game.position.board.pieceCount()
        presentation.confidence = 1
        presentation.confidenceBasis = "稳定合法着法差分"
        presentation.recoveryNeedsAttention = false
        presentation.recoveryHasCandidate = false
        presentation.recoveryProgressText = "已由稳定局部变化自动恢复"
        recoveryCandidate = nil
        rejectedChangeKey = nil
        rejectedChangeFirstSeenAt = nil
        recoveredOrAttemptedChangeKey = nil
        pendingObservedMove = nil
        blockingError = nil
        synchronizePresentation(position: game.position)
        for item in recovered {
            await recordObservedMove(item.move, before: item.before, after: item.after)
        }
        presentation.recordEvent(
            title: "已由稳定局部变化恢复",
            detail: "\(moves.map(\.ucci).joined(separator: " → ")) · 未调用全盘识别或云端模型",
            symbolName: "checkmark.shield.fill",
            tone: .success
        )

        if resumeAutomation {
            try await clickExecutor.arm()
            presentation.isPaused = false
            presentation.phase = .observing
            statusMessage = "局部恢复完成，已继续自动监控"
            await analyzeCurrentPosition()
        } else {
            presentation.isPaused = true
            presentation.phase = .previewing
            statusMessage = "局部恢复完成，保持暂停等待继续"
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
        if presentation.selectedGame != .xiangqi {
            guard gridState.calibration != nil else {
                blockingError = "请先完成交点棋盘标定"
                return
            }
            guard positionIsTrusted else {
                blockingError = "请先识别并确认当前局面"
                return
            }
            gridState.controlledSide = gridControlledSide
            gridState.controlsBothSides = gridControlsBothSides
            presentation.gridSelfPlayEnabled = gridControlsBothSides
            blockingError = nil
            presentation.safetyNotice = nil
            setupStep = .ready
            presentation.isPaused = false
            presentation.phase = .observing
            try? await gridState.clickExecutor.arm()
            statusMessage = "\(presentation.selectedGame.title)驾驶舱已就绪"
            presentation.recordEvent(
                title: "驾驶舱开始实时监控",
                detail: "\(presentation.gridStones.count)枚棋子 · \(gridControlsBothSides ? "双方自动自测" : "我方\(gridControlledSide == .black ? "黑方" : "白方")")",
                symbolName: "waveform.path.ecg",
                tone: .success
            )
            await analyzeGridPosition()
            return
        }
        guard calibration != nil else {
            blockingError = "请先完成棋盘标定"
            return
        }
        guard positionIsTrusted else {
            blockingError = "请先应用人工校正，将当前局面设为可信基准"
            return
        }
        blockingError = nil
        presentation.safetyNotice = nil
        setupStep = .ready
        presentation.isPaused = false
        presentation.phase = .observing
        try? await clickExecutor.arm()
        if var restored = restoredSessionForSetup,
           restored.currentFEN == game.position.fen {
            restored.targetApplicationName = presentation.source.applicationName
            restored.targetBundleIdentifier = selectedBundleIdentifier
            restored.targetWindowTitle = presentation.source.windowTitle
            session = restored
            try? await sessionStore.save(restored)
        } else {
            let newSession = XiangqiSessionRecord(
                title: "中国象棋 \(Date().formatted(date: .abbreviated, time: .shortened))",
                targetApplicationName: presentation.source.applicationName,
                targetBundleIdentifier: selectedBundleIdentifier,
                targetWindowTitle: presentation.source.windowTitle,
                initialFEN: game.position.fen,
                currentFEN: game.position.fen
            )
            session = newSession
            try? await sessionStore.save(newSession)
        }
        restoredSessionForSetup = nil
        statusMessage = "象棋视觉驾驶舱已就绪"
        presentation.recordEvent(
            title: "驾驶舱开始实时监控",
            detail: "\(game.position.board.pieceCount())枚棋子 · \(game.position.sideToMove == .red ? "红方" : "黑方")走",
            symbolName: "waveform.path.ecg",
            tone: .success
        )
        await analyzeCurrentPosition()
    }

    private func analyzeGridPosition() async {
        guard presentation.selectedGame != .xiangqi else { return }
        presentation.phase = .thinking
        let recommendation: GridGameRecommendation?
        switch presentation.selectedGame {
        case .gomoku:
            guard let position = gridState.gomokuPosition else { return }
            gridSideToMove = position.sideToMove
            recommendation = GomokuHeuristicEngine.bestMove(in: position).map { point in
                GridGameRecommendation(coordinate: point, notation: gridNotation(point), score: 80, reason: "本地连五战术与阻挡校验")
            }
        case .go:
            guard let position = gridState.goPosition else { return }
            gridSideToMove = position.sideToMove
            recommendation = GridGameAdvisor.go(position)
        case .xiangqi:
            return
        }
        guard gridState.controlsBothSides || gridSideToMove == gridState.controlledSide,
              let recommendation,
              let coordinate = recommendation.coordinate else {
            presentation.candidates = [.unavailable]
            presentation.selectedCandidateID = CandidateMove.unavailable.id
            presentation.phase = .observing
            statusMessage = (gridState.controlsBothSides || gridSideToMove == gridState.controlledSide)
                ? "当前局面没有安全候选，请人工确认"
                : "等待对方在目标窗口落子…"
            return
        }
        let candidate = CandidateMove(
            id: "grid:\(coordinate.column),\(coordinate.row)",
            notation: recommendation.notation,
            origin: BoardCoordinate(column: coordinate.column, row: coordinate.row),
            target: BoardCoordinate(column: coordinate.column, row: coordinate.row),
            score: recommendation.score,
            evaluation: "本地规则",
            reason: recommendation.reason
        )
        presentation.candidates = [candidate]
        presentation.selectedCandidateID = candidate.id
        presentation.phase = .previewing
        statusMessage = "\(presentation.selectedGame.title)候选已通过规则校验"
        scheduleAutomaticExecutionIfEligible()
    }

    private func gridNotation(_ coordinate: GridCoordinate) -> String {
        let letters = Array("ABCDEFGHJKLMNOPQRST")
        let letter = coordinate.column < letters.count ? String(letters[coordinate.column]) : "?"
        return "\(letter)\(coordinate.row + 1)"
    }

    func analyzeCurrentPosition(level: ThinkingLevel = .standard) async {
        analysisTask?.cancel()
        let position = game.position
        if handleRuleTerminalPositionIfNeeded(position) {
            return
        }
        guard presentation.selectedGame != .xiangqi
            || position.sideToMove == xiangqiControlledSide else {
            automaticExecutionToken = nil
            presentation.candidates = [.unavailable]
            presentation.selectedCandidateID = CandidateMove.unavailable.id
            presentation.phase = .observing
            presentation.isPaused = false
            statusMessage = "等待\(position.sideToMove == .red ? "红方" : "黑方")在目标窗口落子…"
            return
        }
        let analysisStartedAt = ProcessInfo.processInfo.systemUptime
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
                    self.lastAnalysisDurationMilliseconds = Int(
                        (ProcessInfo.processInfo.systemUptime - analysisStartedAt) * 1_000
                    )
                    self.statusMessage = "Pikafish 已完成分析"
                } else {
                    let engine = self.localEngine
                    let analysis = try await Task.detached(priority: .userInitiated) {
                        try await engine.analyze(position: position, level: level, maxCandidates: 3)
                    }.value
                    try Task.checkCancellation()
                    guard self.game.position.key == analysis.positionKey else { return }
                    self.applyAnalysis(analysis)
                    self.lastAnalysisDurationMilliseconds = Int(
                        (ProcessInfo.processInfo.systemUptime - analysisStartedAt) * 1_000
                    )
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
                        self.lastAnalysisDurationMilliseconds = Int(
                            (ProcessInfo.processInfo.systemUptime - analysisStartedAt) * 1_000
                        )
                        return
                    }
                }
                self.blockingError = "引擎分析失败：\(error.localizedDescription)"
                self.presentation.phase = .observing
            }
        }
    }

    @discardableResult
    private func handleRuleTerminalPositionIfNeeded(_ position: Position) -> Bool {
        let result: (winner: Side, detail: String)?
        switch position.status {
        case let .checkmate(loser, winner):
            result = (winner, "\(sideName(loser))方被将死")
        case let .stalemate(loser, winner):
            result = (winner, "\(sideName(loser))方无合法着法")
        case let .generalCaptured(loser, winner):
            result = (winner, "\(sideName(loser))方将帅已失")
        case .ongoing, .check:
            result = nil
        }
        guard let result else { return false }

        analysisTask?.cancel()
        automaticExecutionToken = nil
        presentation.candidates = [.unavailable]
        presentation.selectedCandidateID = CandidateMove.unavailable.id
        presentation.phase = .observing
        presentation.isPaused = true
        Task { [clickExecutor] in await clickExecutor.pause(.userRequested) }
        statusMessage = "对局结束：\(sideName(result.winner))方胜（\(result.detail)）"
        if lastRuleTerminalPositionKey != position.key {
            lastRuleTerminalPositionKey = position.key
            presentation.recordEvent(
                title: "规则确认对局结束",
                detail: "\(sideName(result.winner))方胜 · \(result.detail) · 本地棋规已验证",
                symbolName: "flag.checkered",
                tone: .success
            )
        }
        return true
    }

    private func sideName(_ side: Side) -> String {
        side == .red ? "红" : "黑"
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
        if candidate.id.hasPrefix("grid:") {
            await executeGridMove(candidate)
            return
        }
        automaticExecutionToken = nil
        guard !executionInProgress else {
            statusMessage = "当前落子正在执行，请勿重复确认"
            return
        }
        executionInProgress = true
        defer { executionInProgress = false }
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
            let preparationStartedAt = ProcessInfo.processInfo.systemUptime
            let frame = try await prepareTargetForInputWithRetry(
                ownerPID: target.ownerPID,
                windowID: target.windowID,
                calibration: calibration,
                targetName: presentation.source.applicationName
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
            if isWebMoveLogTarget(windowTitle: target.title) {
                // The Xah Lee board paints its animation and appends its DOM
                // score asynchronously.  `waitForExpectedPosition` has
                // already proved the exact legal move in the official score;
                // do not reject it merely because a later capture has the old
                // pixels or an already-arrived reply.
                _ = try await clickExecutor.verifyAuthoritativeMoveRecord(
                    receipt,
                    afterBoardStateHash: positionHash(verification.position)
                )
            } else {
                _ = try await clickExecutor.verify(
                    receipt,
                    afterBoardStateHash: positionHash(verification.position),
                    capture: capture
                )
            }
            _ = try game.play(move)
            let positionAfterExecutedMove = game.position
            lastAcceptedVisualMoveAt = ProcessInfo.processInfo.systemUptime
            sideToMove = game.position.sideToMove
            // Preserve the exact frame that proved this move. The target may
            // answer immediately; using a later frame here would silently
            // absorb that reply without applying it to the digital position.
            trustedBoardSignature = verification.signature
            lastReconciledFrameSequence = verification.signature.frameSequence
            if let reply = verification.opponentReply {
                let beforeReply = game.position
                _ = try game.play(reply)
                lastAcceptedVisualMoveAt = ProcessInfo.processInfo.systemUptime
                sideToMove = game.position.sideToMove
                await recordObservedMove(reply, before: beforeReply, after: game.position)
            }
            synchronizePresentation(position: game.position)
            await recordExecutedMove(move, before: positionBefore, after: positionAfterExecutedMove)
            PilotDiagnosticLogger.timing(
                "confirmed_move_total",
                milliseconds: (ProcessInfo.processInfo.systemUptime - actionStartedAt) * 1_000
            )
            statusMessage = verification.opponentReply.map {
                "数字棋盘已连续同步：\(move.ucci) → \($0.ucci)"
            } ?? "数字棋盘已同步：\(move.ucci)，等待对方应招…"
            presentation.recordEvent(
                title: verification.opponentReply == nil ? "落子执行并验证" : "双方着法连续同步",
                detail: verification.opponentReply.map {
                    "\(move.ucci) → \($0.ucci) · 目标程序合并刷新"
                } ?? "\(move.ucci) · 数字棋盘已同步为\(game.position.board.pieceCount())枚",
                symbolName: "cursorarrow.click.2",
                tone: .success
            )
            // v0.2.0: Do NOT analyze immediately. It is now the opponent's
            // turn; analyzing would make automatic mode try to play the
            // opponent's move while the target app is still thinking/animating.
            // Enter observing mode; reconcileTrustedPosition() will detect the
            // opponent's response and trigger analysis at that point.
            presentation.phase = .observing
            if verification.opponentReply != nil {
                await analyzeCurrentPosition()
            }
        } catch {
            let diagnostic = PilotDiagnostic(error: error)
            await clickExecutor.pause(.verificationFailed(diagnostic.displayText))
            pause(reason: diagnostic.displayText)
        }
    }

    private func executeGridMove(_ candidate: CandidateMove) async {
        automaticExecutionToken = nil
        guard !executionInProgress,
              let coordinate = gridCoordinate(from: candidate.id),
              let calibration = gridState.calibration else {
            return
        }
        // Re-read the locked window immediately before arming input.  The
        // client can finish a game between candidate publication and this
        // task running; never send a board click into a newly appeared result
        // card.
        if let frame = try? await capture.latestFrame(),
           finishGridGameIfTerminalVisible(in: frame) {
            return
        }
        executionInProgress = true
        defer { executionInProgress = false }
        do {
            try await gridState.clickExecutor.arm()
            presentation.phase = .acting
            let receipt = try await gridState.clickExecutor.executeTap(
                at: coordinate,
                calibration: calibration,
                capture: capture
            )
            presentation.phase = .verifying
            // First prove that the locked target changed after the click. A
            // Unity last-move badge can temporarily cover most of a white
            // stone, so exact colour occupancy is a stronger *second* check,
            // not the only acknowledgement of an already-proven board tap.
            try await gridState.clickExecutor.verify(receipt, capture: capture)
            let outcome: GridMoveOutcome
            do {
                outcome = try await waitForGridMove(
                    coordinate: coordinate,
                    afterSequence: receipt.beforeFrameSequence,
                    timeout: .seconds(3)
                )
            } catch GridClickExecutorError.verificationUnchanged {
                outcome = try expectedGridOutcome(for: coordinate)
                statusMessage = "目标棋盘已确认变化；颜色标记待下一稳定帧复核"
            }
            if case .terminal = outcome {
                return
            }
            applyGridOutcome(outcome, executed: coordinate)
            presentation.phase = .observing
            statusMessage = "数字棋盘已同步：\(gridNotation(coordinate))"
            presentation.recordEvent(
                title: "落子执行并验证",
                detail: "\(gridNotation(coordinate)) · 规则与画面校验通过",
                symbolName: "cursorarrow.click.2",
                tone: .success
            )
            await analyzeGridPosition()
        } catch {
            await gridState.clickExecutor.pause()
            pause(reason: "[GridClickExecutor] \(error.localizedDescription)")
        }
    }

    private enum GridMoveOutcome {
        case gomoku(GomokuPosition)
        case go(GoPosition)
        case terminal(GridTerminalResult)
    }

    private func waitForGridMove(
        coordinate: GridCoordinate,
        afterSequence: UInt64,
        timeout: Duration = .seconds(20)
    ) async throws -> GridMoveOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastSequence = afterSequence
        var expectedGomokuPosition: GomokuPosition?
        var expectedGomokuObservedAt: ContinuousClock.Instant?
        while clock.now < deadline {
            if let frame = try? await capture.latestFrame(),
               frame.sequence > lastSequence,
               let calibration = gridState.calibration {
                lastSequence = frame.sequence
                if finishGridGameIfTerminalVisible(in: frame) {
                    return .terminal(detectedGridTerminal ?? .draw)
                }
                let observed = GridStoneRecognizer.recognize(image: frame.image, calibration: calibration).stones
                switch presentation.selectedGame {
                case .gomoku:
                    guard let current = gridState.gomokuPosition,
                          let expected = try? current.applying(coordinate) else { break }
                    if observed == expected.stones {
                        // The installed 人机五子棋 client often paints our
                        // stone one frame before its built-in AI replies. In
                        // both-sides self-test mode, accepting that first
                        // frame immediately makes the cockpit try to place
                        // the AI's white move too, producing a double-paced
                        // board and eventual recognition drift. Hold the
                        // exact expected frame briefly so a real, legal
                        // client reply can be absorbed as one verified
                        // transition. If the client is genuinely passive,
                        // preserve the existing self-test fallback below.
                        expectedGomokuPosition = expected
                        if expectedGomokuObservedAt == nil {
                            expectedGomokuObservedAt = clock.now
                        }
                        if !gridState.controlsBothSides
                            || expectedGomokuObservedAt!.duration(to: clock.now) >= .seconds(2) {
                            return .gomoku(expected)
                        }
                        continue
                    }
                    if let reply = GridGameTransitionPolicy.nextGomokuMove(from: expected, observed: observed),
                       let afterReply = try? expected.applying(reply) {
                        return .gomoku(afterReply)
                    }
                case .go:
                    guard let current = gridState.goPosition,
                          let expected = try? current.applying(.play(coordinate)) else { break }
                    if observed == expected.stones { return .go(expected) }
                    if let reply = GridGameTransitionPolicy.nextGoMove(from: expected, observed: observed),
                       let afterReply = try? expected.applying(reply) {
                        return .go(afterReply)
                    }
                case .xiangqi:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(45))
        }
        if let expectedGomokuPosition {
            return .gomoku(expectedGomokuPosition)
        }
        throw GridClickExecutorError.verificationUnchanged
    }

    private func expectedGridOutcome(for coordinate: GridCoordinate) throws -> GridMoveOutcome {
        switch presentation.selectedGame {
        case .gomoku:
            guard let current = gridState.gomokuPosition else { throw GridClickExecutorError.verificationUnchanged }
            return .gomoku(try current.applying(coordinate))
        case .go:
            guard let current = gridState.goPosition else { throw GridClickExecutorError.verificationUnchanged }
            return .go(try current.applying(.play(coordinate)))
        case .xiangqi:
            throw GridClickExecutorError.verificationUnchanged
        }
    }

    private func applyGridOutcome(_ outcome: GridMoveOutcome, executed: GridCoordinate? = nil) {
        switch outcome {
        case let .gomoku(position):
            gridState.gomokuPosition = position
            gridSideToMove = position.sideToMove
            gridState.lastObservedStones = position.stones
            synchronizeGridPresentation(stones: position.stones, lineCount: position.size)
            handleGridTerminal(position.status)
        case let .go(position):
            gridState.goPosition = position
            gridSideToMove = position.sideToMove
            gridState.lastObservedStones = position.stones
            synchronizeGridPresentation(stones: position.stones, lineCount: position.size)
            handleGridTerminal(position.status)
        case .terminal:
            return
        }
        if executed != nil {
            lastAcceptedGridMoveAt = ProcessInfo.processInfo.systemUptime
            lastAcceptedGridCoordinate = executed
        }
    }

    private func handleGridTerminal(_ status: GomokuStatus) {
        guard case let .win(winner) = status else { return }
        finishGridGame("\(winner == .black ? "黑" : "白")方连五获胜")
    }

    private func handleGridTerminal(_ status: GoStatus) {
        guard case let .finished(black, white) = status else { return }
        let winner = black == white ? "和棋" : (black > white ? "黑方胜" : "白方胜")
        finishGridGame("\(winner) · 终局数子 黑\(black) : 白\(white)")
    }

    /// Returns true for every frame that visibly belongs to a terminal card,
    /// not just the first one.  Callers must use the return value to prevent
    /// result-card artwork from reaching the board recognizer.
    @discardableResult
    private func finishGridGameIfTerminalVisible(in frame: CapturedFrame) -> Bool {
        guard presentation.selectedGame != .xiangqi,
              !gridBootstrapInProgress else { return false }

        if let conceded = pendingConcededGridTerminal,
           GridTerminalRecognizer.recognizesTerminalOverlay(image: frame.image) {
            pendingConcededGridTerminal = nil
            lastGridTerminalResult = conceded
            detectedGridTerminal = conceded
            finishGridGame("\(presentation.selectedGame.title)客户端终局：\(conceded.title)")
            return true
        }

        guard let terminal = GridTerminalRecognizer.recognize(image: frame.image) else {
            return false
        }
        let needsAnnouncement = detectedGridTerminal != terminal
            || lastGridTerminalResult != terminal
            || !presentation.isPaused
        lastGridTerminalResult = terminal
        detectedGridTerminal = terminal
        if needsAnnouncement {
            finishGridGame("\(presentation.selectedGame.title)客户端终局：\(terminal.title)")
        }
        return true
    }

    private func finishGridGame(_ detail: String) {
        automaticExecutionToken = nil
        pendingGridUnexplainedObservation = nil
        pendingGridUnexplainedCount = 0
        blockingError = nil
        presentation.isPaused = true
        presentation.phase = .observing
        presentation.candidates = [.unavailable]
        presentation.selectedCandidateID = CandidateMove.unavailable.id
        statusMessage = "对局结束：\(detail)"
        presentation.recordEvent(
            title: "规则确认对局结束",
            detail: detail,
            symbolName: "flag.checkered",
            tone: .success
        )
        Task { [gridState] in await gridState.clickExecutor.pause() }
    }

    private func gridCoordinate(from identifier: String) -> GridCoordinate? {
        let values = identifier.dropFirst("grid:".count).split(separator: ",")
        guard values.count == 2, let column = Int(values[0]), let row = Int(values[1]) else { return nil }
        return GridCoordinate(column: column, row: row)
    }

    /// Retries only before any mouse event has been posted.  Once execution
    /// reaches `ClickExecutor.execute`, a failed verification is treated as an
    /// uncertain outcome and is never blindly clicked again.
    private func prepareTargetForInputWithRetry(
        ownerPID: pid_t,
        windowID: CGWindowID,
        calibration: BoardCalibration,
        targetName: String
    ) async throws -> CapturedFrame {
        var latestError: Error?
        for attempt in 1...3 {
            do {
                try await clickExecutor.arm()
                return try await clickExecutor.prepareTargetForInput(
                    ownerPID: ownerPID,
                    windowID: windowID,
                    calibration: calibration,
                    capture: capture
                )
            } catch {
                latestError = error
                guard isRetryablePreflightError(error), attempt < 3 else { throw error }
                let diagnostic = PilotDiagnostic(error: error)
                statusMessage = "正在重新激活\(targetName)：\(diagnostic.message)（第\(attempt)次重试）"
                PilotDiagnosticLogger.event(
                    "preflight_retry attempt=\(attempt) error=\(diagnostic.code)"
                )
                try? await Task.sleep(for: .milliseconds(240 * attempt))
            }
        }
        throw latestError ?? ClickExecutorError.targetWindowMissing
    }

    private func isRetryablePreflightError(_ error: Error) -> Bool {
        guard let error = error as? ClickExecutorError else { return false }
        switch error {
        case .targetNotFrontmost, .targetWindowOccluded, .frameNotStable:
            return true
        default:
            return false
        }
    }

    private func waitForExpectedPosition(
        _ expected: Position,
        after sequence: UInt64,
        move: Move,
        beforeBoardSignature: BoardFrameSignature
    ) async throws -> VerifiedMoveSequence {
        if let target = await capture.lockedTarget(),
           isWebMoveLogTarget(windowTitle: target.title) {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            let expectedPlyIndex = game.records.count
            while clock.now < deadline {
                if XiangqiWebMoveLogReader.latestLegalMove(
                    ownerPID: target.ownerPID,
                    expectedPlyIndex: expectedPlyIndex,
                    position: game.position
                ) == move {
                    let frame = try await capture.latestFrame()
                    let signature = if let calibration {
                        boardDifferencer.signature(
                            image: frame.image,
                            frameSequence: frame.sequence,
                            geometry: recognitionGeometry(from: calibration)
                        )
                    } else {
                        beforeBoardSignature
                    }
                    PilotDiagnosticLogger.event(
                        "expected_move_confirmed_by_web_record move=\(move.ucci) ply=\(expectedPlyIndex + 1)"
                    )
                    return VerifiedMoveSequence(
                        position: expected,
                        signature: signature,
                        opponentReply: nil
                    )
                }
                try await Task.sleep(for: .milliseconds(35))
            }
            throw ClickExecutorError.verificationBoardStateUnchanged
        }
        let clock = ContinuousClock()
        // Some target programs animate or think before committing a move. Keep
        // observing long enough to accept that delayed result, but make the hot
        // path cheap: board fingerprints first, OCR only for a settled complex
        // change. This also prevents OCR work from starving the target app.
        let startedAt = clock.now
        // 象棋巫师 may take 16–20 seconds before publishing our move and its
        // reply together. The previous 15-second deadline expired one frame
        // before that redraw in a real run.
        let deadline = startedAt.advanced(by: .seconds(30))
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
                    return VerifiedMoveSequence(
                        position: expected,
                        signature: afterSignature,
                        opponentReply: nil
                    )
                }

                if let reply = RecognitionTransitionPolicy.decoratedLegalReply(
                    trusted: game.position,
                    firstMove: move,
                    orientation: orientation,
                    visualChange: visualChange
                ), let afterReply = try? expected.applying(reply) {
                    PilotDiagnosticLogger.event(
                        "expected_move_and_reply_detected first=\(move.ucci) reply=\(reply.ucci) frame=\(frame.sequence)"
                    )
                    return VerifiedMoveSequence(
                        position: afterReply,
                        signature: afterSignature,
                        opponentReply: reply
                    )
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
                            geometry: geometry,
                            targetBundleIdentifier: selectedBundleIdentifier
                        )
                        if let observed = try? makePosition(from: snapshot),
                           PositionVerificationPolicy.matches(observed: observed, expected: expected) {
                            PilotDiagnosticLogger.event(
                                "expected_move_detected_by_ocr move=\(move.ucci) frame=\(frame.sequence)"
                            )
                            return VerifiedMoveSequence(
                                position: expected,
                                signature: afterSignature,
                                opponentReply: nil
                            )
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
                            return VerifiedMoveSequence(
                                position: expected,
                                signature: afterSignature,
                                opponentReply: nil
                            )
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
        PilotDiagnosticLogger.event("target_response_timeout_30_seconds move=\(move.ucci)")
        throw ClickExecutorError.verificationBoardStateUnchanged
    }

    private func isWebMoveLogTarget(windowTitle: String) -> Bool {
        XiangqiWebMoveLogReader.matches(
            bundleIdentifier: selectedBundleIdentifier,
            windowTitle: windowTitle
        )
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
              !concedingGridGame,
              !presentation.isPaused,
              !presentation.isEmergencyStopped,
              positionIsTrusted,
              presentation.phase == .previewing else {
            return
        }
        let candidate = presentation.selectedCandidate
        guard candidate.id != CandidateMove.unavailable.id else {
            return
        }
        let executable = switch presentation.selectedGame {
        case .xiangqi: Move(ucci: candidate.id) != nil
        case .gomoku, .go: gridCoordinate(from: candidate.id) != nil
        }
        guard executable else { return }
        let positionKey = automaticPositionBindingKey()
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
                  self.automaticPositionBindingKey() == positionKey,
                  self.presentation.selectedCandidate.id == candidate.id else {
                if self?.automaticExecutionToken == token {
                    self?.automaticExecutionToken = nil
                }
                return
            }
            await self.execute(candidate)
        }
    }

    /// Every scheduled click is bound to the exact recognised position.  The
    /// Xiangqi FEN key cannot protect a Gomoku/Go candidate because those
    /// games intentionally use their own rule cores.
    private func automaticPositionBindingKey() -> String {
        switch presentation.selectedGame {
        case .xiangqi:
            String(describing: game.position.key)
        case .gomoku:
            gridPositionBindingKey(
                stones: gridState.gomokuPosition?.stones ?? [:],
                side: gridState.gomokuPosition?.sideToMove
            )
        case .go:
            gridPositionBindingKey(
                stones: gridState.goPosition?.stones ?? [:],
                side: gridState.goPosition?.sideToMove
            )
        }
    }

    private func gridPositionBindingKey(
        stones: [GridCoordinate: GridStone],
        side: GridStone?
    ) -> String {
        let placement = stones.sorted { $0.key < $1.key }
            .map { "\($0.key.column),\($0.key.row),\($0.value.rawValue)" }
            .joined(separator: ";")
        return "grid:\(side?.rawValue ?? "none")|\(placement)"
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
        // Register the Alibaba providers for explicit opt-in, but do not
        // silently enable cloud vision on launch. Local recognition remains
        // the default and avoids an unexpected paid/slow recovery call.
        presentation.modelSource = .off
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
                // A single visual model can return a legal but visually wrong
                // FEN. Keep its result as a correction draft; only the user or
                // independent evidence may establish the first trusted board.
                positionIsTrusted = false
                recognizedPieceCount = position.board.pieceCount()
                trustedBoardSignature = nil
                presentation.confidence = response.confidence
                presentation.confidenceBasis = "\(attempt.label)（等待确认）"
                synchronizePresentation(position: position)
                recognitionWarnings = response.warnings + [
                    "\(attempt.label)已生成合法局面草稿；模型结果不能单独建立可信基准，请与真实棋盘核对。"
                ]
                statusMessage = "\(attempt.label)已生成\(recognizedPieceCount)枚局面草稿，等待确认"
                presentation.recordEvent(
                    title: "云端局面等待人工确认",
                    detail: "\(attempt.label) · \(recognizedPieceCount)枚 · 置信度\(Int(response.confidence * 100))%",
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .attention
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

    private static func cornerPreset(
        for bundleIdentifier: String?,
        windowTitle: String
    ) -> NormalizedBoardCorners? {
        if bundleIdentifier == "com.jpcxc.xqwiphone" {
            // 象棋巫师的棋盘在窗口左侧，右侧是对局信息栏。
            return NormalizedBoardCorners(
                topLeft: CGPoint(x: 0.086, y: 0.165),
                topRight: CGPoint(x: 0.607, y: 0.165),
                bottomLeft: CGPoint(x: 0.086, y: 0.902),
                bottomRight: CGPoint(x: 0.607, y: 0.902)
            )
        }
        if XiangqiWebMoveLogReader.matches(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle
        ) {
            // Xah Lee's board fills Chrome's content column. This is only a
            // starting point: the setup canvas remains the authority.
            return NormalizedBoardCorners(
                topLeft: CGPoint(x: 0.064, y: 0.151),
                topRight: CGPoint(x: 0.893, y: 0.151),
                bottomLeft: CGPoint(x: 0.064, y: 0.718),
                bottomRight: CGPoint(x: 0.893, y: 0.718)
            )
        }
        return nil
    }

    private static func gridCornerPreset(
        for game: GameKind,
        bundleIdentifier: String?
    ) -> NormalizedBoardCorners? {
        switch game {
        case .gomoku where bundleIdentifier == "com.sining.wuziqi":
            // Verified against the installed portrait 五子棋 client.  These
            // are the outermost 15×15 intersections, not the decorative wood
            // frame; the setup view still exposes all four handles.
            return NormalizedBoardCorners(
                topLeft: CGPoint(x: 0.055, y: 0.275),
                topRight: CGPoint(x: 0.940, y: 0.275),
                bottomLeft: CGPoint(x: 0.055, y: 0.758),
                bottomRight: CGPoint(x: 0.940, y: 0.758)
            )
        case .go where bundleIdentifier == "com.tencent.TtgoForIos":
            // Verified against the installed desktop Tencent Go AI board in
            // 19-line mode. The board occupies the left panel; the right
            // panel is player information and controls, not board pixels.
            return NormalizedBoardCorners(
                topLeft: CGPoint(x: 0.035, y: 0.086),
                topRight: CGPoint(x: 0.582, y: 0.086),
                bottomLeft: CGPoint(x: 0.035, y: 0.957),
                bottomRight: CGPoint(x: 0.582, y: 0.957)
            )
        default:
            return nil
        }
    }

    private static func calibrationKey(
        bundleIdentifier: String?,
        windowTitle: String
    ) -> String? {
        guard let bundleIdentifier else { return nil }
        // The installed 五子棋 client needed a corrected outer-intersection
        // preset.  Version this preference so an old, wider calibration does
        // not silently override the repaired geometry after an app update.
        if bundleIdentifier == "com.sining.wuziqi" {
            return "\(bundleIdentifier).grid15.v2"
        }
        if bundleIdentifier == "com.tencent.TtgoForIos" {
            return "\(bundleIdentifier).grid19.v1"
        }
        if XiangqiWebMoveLogReader.matches(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle
        ) {
            return "\(bundleIdentifier).xahlee-xiangqi"
        }
        return bundleIdentifier
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
        if presentation.selectedGame != .xiangqi {
            let now = ProcessInfo.processInfo.systemUptime
            // Setup previews can legitimately show a previous game's result
            // while the cockpit is locating the board and starting a fresh
            // local match. A terminal is meaningful only after calibration
            // has been confirmed and normal board monitoring is active.
            if setupStep == .ready,
               !gridBootstrapInProgress,
               now - lastGridTerminalRecognitionAt >= 0.75 {
                lastGridTerminalRecognitionAt = now
                // Always consume a visible terminal frame.  Previously only
                // the first matching result returned here; subsequent frames
                // fell through to stone recognition, so the result artwork
                // eventually overwrote a valid 14-stone game as an impossible
                // 76-stone board.
                if finishGridGameIfTerminalVisible(in: frame) {
                    return
                }
            }
            reconcileGridPosition(from: frame)
            return
        }
        reconcileTrustedPosition(from: frame)
    }

    private func reconcileGridPosition(from frame: CapturedFrame) {
        guard setupStep == .ready,
              positionIsTrusted,
              !presentation.isPaused,
              detectedGridTerminal == nil,
              !executionInProgress,
              frame.sequence > lastGridReconciledFrameSequence,
              let calibration = gridState.calibration else { return }
        // ScreenCaptureKit streams the exact locked target even while the
        // cockpit is frontmost.  Requiring foreground ownership here made
        // the dashboard stop seeing legitimate opponent replies whenever the
        // user followed the cockpit-only workflow.  Rule validation below is
        // the safety boundary, not macOS focus state.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGridRecognitionAt >= 0.20 else { return }
        lastGridRecognitionAt = now
        lastGridReconciledFrameSequence = frame.sequence
        let observed = GridStoneRecognizer.recognize(image: frame.image, calibration: calibration).stones
        guard observed != gridState.lastObservedStones else {
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            return
        }
        switch presentation.selectedGame {
        case .gomoku:
            guard let current = gridState.gomokuPosition,
                  let move = GridGameTransitionPolicy.nextGomokuMove(from: current, observed: observed),
                  let next = try? current.applying(move) else {
                deferGridPauseIfObservationPersists(
                    observed,
                    reason: "五子棋画面变化连续三帧无法由唯一合法着法解释"
                )
                return
            }
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            applyGridOutcome(.gomoku(next))
            presentation.recordEvent(
                title: "数字棋盘已实时同步",
                detail: "对方或人工落子：\(gridNotation(move))",
                symbolName: "eye.fill",
                tone: .success
            )
        case .go:
            guard let current = gridState.goPosition,
                  let move = GridGameTransitionPolicy.nextGoMove(from: current, observed: observed),
                  let next = try? current.applying(move) else {
                deferGridPauseIfObservationPersists(
                    observed,
                    reason: "围棋画面变化连续三帧无法由唯一合法着法解释"
                )
                return
            }
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            applyGridOutcome(.go(next))
            presentation.recordEvent(
                title: "数字棋盘已实时同步",
                detail: "对方或人工落子：\(gridMoveDescription(move))",
                symbolName: "eye.fill",
                tone: .success
            )
        case .xiangqi:
            return
        }
        Task { [weak self] in await self?.analyzeGridPosition() }
    }

    private func deferGridPauseIfObservationPersists(
        _ observed: [GridCoordinate: GridStone],
        reason: String
    ) {
        // The actual board tap was already confirmed by the locked target's
        // changed stream. A transient mismatch immediately afterwards is most
        // commonly the client's last-move halo/marker, not a second move.
        // Let the marker settle; a real reply remains accepted earlier by the
        // unique-legal-move path in `reconcileGridPosition`.
        if let lastAcceptedGridMoveAt,
           ProcessInfo.processInfo.systemUptime - lastAcceptedGridMoveAt <= 15.0 {
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            statusMessage = "已验证落子，正在等待棋盘标记稳定…"
            return
        }
        // Tencent Go keeps a dark last-move marker on a white stone. Once a
        // cockpit click has been verified, an observation with the exact same
        // occupied intersections but a different colour sample is therefore
        // not a move and must never safety-pause the game. Keep the proven
        // digital position until a rule-valid reply or a materially different
        // board is observed.
        if GridGameTransitionPolicy.hasMatchingOccupancy(
            trusted: gridState.lastObservedStones,
            observed: observed
        ) {
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            statusMessage = "棋子坐标一致，正在等待最后一手标记稳定…"
            return
        }
        if let lastAcceptedGridCoordinate,
           GridGameTransitionPolicy.differsOnlyAt(
            lastAcceptedGridCoordinate,
            trusted: gridState.lastObservedStones,
            observed: observed
           ) {
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            statusMessage = "已锚定最后落点，正在等待棋盘标记稳定…"
            return
        }
        // We have already proved our own click and the trusted rule position
        // now says that the other side must move. A non-rule visual frame in
        // this phase cannot authorize another cockpit click. Tencent Go may
        // repaint decorations or shadows at unrelated intersections, so keep
        // the proven position and wait for a frame that explains exactly one
        // legal opponent move instead of stopping a healthy automatic match.
        // If the opponent really plays, the unique-legal-move path above wins
        // before reaching this guard.
        if !gridState.controlsBothSides,
           gridSideToMove != gridState.controlledSide {
            pendingGridUnexplainedObservation = nil
            pendingGridUnexplainedCount = 0
            statusMessage = "等待对方落子：已忽略未通过规则校验的客户端装饰帧…"
            return
        }
        if pendingGridUnexplainedObservation == observed {
            pendingGridUnexplainedCount += 1
        } else {
            pendingGridUnexplainedObservation = observed
            pendingGridUnexplainedCount = 1
        }
        guard pendingGridUnexplainedCount >= 3 else {
            statusMessage = "正在复核棋盘瞬时变化（\(pendingGridUnexplainedCount)/3）"
            return
        }
        let diagnostic = gridObservationDifference(trusted: gridState.lastObservedStones, observed: observed)
        PilotDiagnosticLogger.event("grid_reconciliation_pause \(diagnostic)")
        presentation.recordEvent(
            title: "围棋识别差异待恢复",
            detail: diagnostic,
            symbolName: "exclamationmark.triangle",
            tone: .attention
        )
        pause(reason: "\(reason) · \(diagnostic)")
    }

    private func gridObservationDifference(
        trusted: [GridCoordinate: GridStone],
        observed: [GridCoordinate: GridStone]
    ) -> String {
        func notationList(_ points: [GridCoordinate]) -> String {
            let values = points.sorted {
                $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
            }.map(gridNotation)
            return values.isEmpty ? "无" : values.joined(separator: ",")
        }
        let missing = trusted.keys.filter { observed[$0] == nil }
        let unexpected = observed.keys.filter { trusted[$0] == nil }
        let recolored = trusted.keys.filter { point in
            guard let trustedStone = trusted[point],
                  let observedStone = observed[point] else { return false }
            return observedStone != trustedStone
        }
        let anchor = lastAcceptedGridCoordinate.map(gridNotation) ?? "无"
        return "可信\(trusted.count)/观测\(observed.count)；末着\(anchor)；缺\(notationList(missing))；多\(notationList(unexpected))；变色\(notationList(recolored))"
    }

    private func gridMoveDescription(_ move: GoMove) -> String {
        switch move {
        case let .play(point): gridNotation(point)
        case .pass: "停一手"
        }
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
        let isWizardTarget = selectedBundleIdentifier == XiangqiWizardMoveLogReader.bundleIdentifier
        let isWebMoveLogTarget = XiangqiWebMoveLogReader.matches(
            bundleIdentifier: selectedBundleIdentifier,
            windowTitle: frame.target.title
        )
        if selectedBundleIdentifier == XiangqiWizardMoveLogReader.bundleIdentifier,
           lastWizardTerminalResult == nil,
           let terminalResult = XiangqiWizardMoveLogReader.terminalResult(
            ownerPID: frame.target.ownerPID
           ) {
            handleWizardTerminalResult(terminalResult)
            return
        }
        // 象棋巫师 substantially dims every piece when its window loses
        // foreground focus. Comparing that inactive rendering with an active
        // trusted frame produces roughly 30 simultaneous changed cells and
        // looks like a catastrophic board mutation. A real GUI move can only
        // be made while the locked target is frontmost, so inactive frames are
        // display-only and must never advance or invalidate the digital board.
        // A browser's official ICCS score is accessible even while the
        // cockpit is frontmost.  Continuing to poll that deterministic record
        // is both safer and more useful than demanding that the user leave the
        // browser on top; no visual/OCR inference is accepted for this route.
        // Pure visual targets still require foreground ownership so inactive
        // rendering cannot be mistaken for a board mutation.
        guard isWebMoveLogTarget
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.target.ownerPID else {
            pendingObservedMove = nil
            rejectedChangeKey = nil
            rejectedChangeFirstSeenAt = nil
            return
        }
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

        // The move row and board animation are not committed in the same
        // render transaction. Check 象棋巫师's exact next record on every
        // observation frame, before classifying the pixel delta as unchanged,
        // decorated, or rejected. The ply index prevents stale rows from being
        // replayed, and the local rules engine must resolve the notation to one
        // and only one legal move.
        let observationUptime = ProcessInfo.processInfo.systemUptime
        let wizardRecordedMove: Move? = if isWizardTarget {
            XiangqiWizardMoveLogReader.latestLegalMove(
                ownerPID: frame.target.ownerPID,
                expectedPlyIndex: game.records.count,
                position: game.position
            ) ?? (observationUptime - lastWizardMoveOCRAttemptAt >= 0.25
                ? {
                    lastWizardMoveOCRAttemptAt = observationUptime
                    return XiangqiWizardMoveLogReader.latestLegalMove(
                    image: frame.image,
                    expectedPlyIndex: game.records.count,
                    position: game.position
                    )
                }()
                : nil)
        } else {
            nil
        }
        let webRecordedMove: Move? = if isWebMoveLogTarget {
            XiangqiWebMoveLogReader.latestLegalMove(
                ownerPID: frame.target.ownerPID,
                expectedPlyIndex: game.records.count,
                position: game.position
            )
        } else {
            nil
        }
        if let recordedMove = wizardRecordedMove ?? webRecordedMove {
            let before = game.position
            do {
                analysisTask?.cancel()
                _ = try game.play(recordedMove)
                lastAcceptedVisualMoveAt = ProcessInfo.processInfo.systemUptime
                sideToMove = game.position.sideToMove
                self.trustedBoardSignature = signature
                pendingObservedMove = nil
                rejectedChangeKey = nil
                rejectedChangeFirstSeenAt = nil
                recoveredOrAttemptedChangeKey = nil
                presentation.confidence = 1
                presentation.confidenceBasis = isWizardTarget
                    ? "象棋巫师走棋记录＋本地棋规"
                    : "网页官方走棋记录＋本地棋规"
                synchronizePresentation(position: game.position)
                statusMessage = "数字棋盘已由确定性记录同步：\(recordedMove.ucci)"
                PilotDiagnosticLogger.event(
                    "deterministic_move_log_confirmed move=\(recordedMove.ucci) ply=\(game.records.count)"
                )
                Task { [weak self] in
                    guard let self else { return }
                    await self.recordObservedMove(recordedMove, before: before, after: self.game.position)
                    await self.analyzeCurrentPosition()
                }
                return
            } catch {
                blockingError = "走棋记录同步失败：\(error.localizedDescription)"
                return
            }
        }
        // A move-list target's board animation can briefly look exactly like a
        // different legal two-endpoint move. Never let that race its official
        // record: both 象棋巫师 and the web adapter are authoritative here.
        if isWizardTarget || isWebMoveLogTarget {
            statusMessage = isWizardTarget
                ? "等待象棋巫师发布第\(game.records.count + 1)步官方记录…"
                : "等待网页发布第\(game.records.count + 1)步官方记录…"
            return
        }
        switch RecognitionTransitionPolicy.decide(
            trusted: game.position,
            orientation: orientation,
            visualChange: visualChange
        ) {
        case .unchanged:
            self.trustedBoardSignature = signature
            pendingObservedMove = nil
            rejectedChangeKey = nil
            rejectedChangeFirstSeenAt = nil
            recoveredOrAttemptedChangeKey = nil
        case .legalMove(let move):
            let before = game.position
            do {
                analysisTask?.cancel()
                _ = try game.play(move)
                lastAcceptedVisualMoveAt = ProcessInfo.processInfo.systemUptime
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
            let now = ProcessInfo.processInfo.systemUptime
            if let decoratedMove = RecognitionTransitionPolicy.decoratedLegalMove(
                trusted: game.position,
                orientation: orientation,
                visualChange: visualChange
            ) {
                if var pending = pendingObservedMove,
                   pending.move == decoratedMove,
                   // Capture normally runs at 20 Hz, but foreground handoff,
                   // animation and engine callbacks can delay a main-actor
                   // reconciliation frame well beyond 120 ms. Keep the same
                   // uniquely legal candidate alive across that scheduling
                   // gap while still requiring repeated stable evidence.
                   now - pending.lastSeenAt <= 0.80 {
                    pending.lastSeenAt = now
                    pendingObservedMove = pending
                    if now - pending.firstSeenAt >= 0.18 {
                        let before = game.position
                        do {
                            analysisTask?.cancel()
                            _ = try game.play(decoratedMove)
                            lastAcceptedVisualMoveAt = ProcessInfo.processInfo.systemUptime
                            sideToMove = game.position.sideToMove
                            self.trustedBoardSignature = signature
                            pendingObservedMove = nil
                            rejectedChangeKey = nil
                            rejectedChangeFirstSeenAt = nil
                            recoveredOrAttemptedChangeKey = nil
                            presentation.confidence = 1
                            presentation.confidenceBasis = "合法着法差分（已过滤高亮）"
                            synchronizePresentation(position: game.position)
                            statusMessage = "数字棋盘已实时同步：\(decoratedMove.ucci)"
                            Task { [weak self] in
                                guard let self else { return }
                                await self.recordObservedMove(decoratedMove, before: before, after: self.game.position)
                                await self.analyzeCurrentPosition()
                            }
                            return
                        } catch {
                            pendingObservedMove = nil
                            blockingError = "实时棋盘同步失败：\(error.localizedDescription)"
                            return
                        }
                    }
                    return
                }
                pendingObservedMove = PendingObservedMove(
                    move: decoratedMove,
                    firstSeenAt: now,
                    lastSeenAt: now
                )
                return
            }
            pendingObservedMove = nil
            // Highlights and animations are usually brief. Only a stable,
            // repeated unexplained pattern enters recovery, so one transient
            // frame can never invoke AI or replace the trusted board.
            let key = visualChange.cells
                .map { "\($0.coordinate.file),\($0.coordinate.rank)" }
                .sorted()
                .joined(separator: ";")
            // After a legal move, 象棋巫师 can remove one corner of its blue
            // last-move marker several frames later. A single changed cell can
            // never prove a Xiangqi move. Wait until that exact decoration is
            // stable, then rebase only the visual signature; do not touch the
            // digital position and do not invoke the cloud recovery path.
            if visualChange.cells.count == 1,
               let lastAcceptedVisualMoveAt,
               now - lastAcceptedVisualMoveAt <= 3.0 {
                if rejectedChangeKey != key {
                    rejectedChangeKey = key
                    rejectedChangeFirstSeenAt = now
                    return
                }
                if let firstSeen = rejectedChangeFirstSeenAt,
                   now - firstSeen >= 0.25 {
                    self.trustedBoardSignature = signature
                    rejectedChangeKey = nil
                    rejectedChangeFirstSeenAt = nil
                    recoveredOrAttemptedChangeKey = nil
                    PilotDiagnosticLogger.event("single_cell_decoration_rebased cell=\(key)")
                }
                return
            }
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

    private func handleWizardTerminalResult(_ result: XiangqiWizardTerminalResult) {
        lastWizardTerminalResult = result
        analysisTask?.cancel()
        automaticExecutionToken = nil
        executionInProgress = false
        presentation.candidates = [.unavailable]
        presentation.selectedCandidateID = CandidateMove.unavailable.id
        presentation.phase = .observing
        presentation.isPaused = true
        presentation.confidence = 1
        presentation.confidenceBasis = "象棋巫师终局公告"
        blockingError = nil
        statusMessage = "对局结束：\(result.title)"
        presentation.recordEvent(
            title: "对局结束·\(result.title)",
            detail: "已由象棋巫师的终局弹窗确认，窗口操作已自动锁定",
            symbolName: result == .win ? "trophy.fill" : "flag.checkered",
            tone: result == .win ? .success : (result == .draw ? .neutral : .attention)
        )
        Task { [weak self] in
            guard let self else { return }
            await self.clickExecutor.pause(.userRequested)
        }
    }

    private func wirePresentationActions() {
        presentation.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            Task { @MainActor in
                if paused {
                    await self.clickExecutor.pause(.userRequested)
                    await self.gridState.clickExecutor.pause()
                } else {
                    do {
                        if self.presentation.selectedGame == .xiangqi {
                            try await self.clickExecutor.arm()
                        } else {
                            try await self.gridState.clickExecutor.arm()
                        }
                        self.blockingError = nil
                        self.presentation.safetyNotice = nil
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
            Task { @MainActor in
                await self.clickExecutor.pause(.manualTakeover)
                await self.gridState.clickExecutor.pause()
            }
        }
        presentation.onResumeAfterStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.presentation.selectedGame == .xiangqi {
                    await self.recognizeCurrentPosition()
                } else {
                    await self.recognizeGridPosition()
                }
            }
        }
        presentation.onRecognizePosition = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.presentation.selectedGame == .xiangqi {
                    await self.recognizeCurrentPosition()
                } else {
                    await self.recognizeGridPosition()
                }
            }
        }
        presentation.onApplyCorrection = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.commitManualPosition() }
        }
        presentation.onConfirmMove = { [weak self] candidate in
            guard let self else { return }
            Task { @MainActor in await self.execute(candidate) }
        }
        presentation.onConcedeCurrentGame = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.concedeCurrentGridGame() }
        }
        presentation.onControlModeChanged = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleAutomaticExecutionIfEligible() }
        }
        presentation.onGridSelfPlayChanged = { [weak self] enabled in
            guard let self else { return }
            Task { @MainActor in
                self.gridControlsBothSides = enabled
                self.gridState.controlsBothSides = enabled
                self.automaticExecutionToken = nil
                guard self.setupStep == .ready,
                      self.presentation.selectedGame != .xiangqi,
                      self.positionIsTrusted else { return }
                self.presentation.recordEvent(
                    title: enabled ? "双方自动自测已开启" : "双方自动自测已关闭",
                    detail: enabled ? "驾驶舱将对双方依次执行规则校验后的候选落点" : "恢复仅我方落子，等待目标窗口对手回手",
                    symbolName: enabled ? "arrow.triangle.2.circlepath" : "person.fill",
                    tone: enabled ? .attention : .neutral
                )
                await self.analyzeGridPosition()
                self.scheduleAutomaticExecutionIfEligible()
            }
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
        presentation.onGameChanged = { [weak self] gameKind in
            guard let self else { return }
            Task { @MainActor in await self.changeGameKind(gameKind) }
        }
    }

    private func pause(reason: String) {
        presentation.isPaused = true
        presentation.phase = .observing
        blockingError = reason
        presentation.safetyNotice = reason
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
            source: presentation.engineSource == .ucci ? .ucciEngine : .localEngine,
            confidence: presentation.confidence,
            thinkingMilliseconds: lastAnalysisDurationMilliseconds,
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
