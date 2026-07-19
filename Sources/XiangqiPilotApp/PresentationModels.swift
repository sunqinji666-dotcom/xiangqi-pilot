import AppKit
import Combine
import Foundation

// MARK: - Navigation and session presentation

enum GameKind: String, CaseIterable, Identifiable {
    case xiangqi
    case go
    case gomoku

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xiangqi: "中国象棋"
        case .go: "围棋"
        case .gomoku: "五子棋"
        }
    }

    var subtitle: String {
        switch self {
        case .xiangqi: "标准九路棋盘"
        case .go, .gomoku: "即将推出"
        }
    }

    var symbolName: String {
        switch self {
        case .xiangqi: "checkerboard.rectangle"
        case .go: "circle.grid.3x3.fill"
        case .gomoku: "circle.grid.cross"
        }
    }

    var isAvailable: Bool { self == .xiangqi }
}

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case cockpit
    case correction
    case review
    case recovery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cockpit: "实时对局"
        case .correction: "任意局面识别"
        case .review: "复盘记录"
        case .recovery: "异常恢复"
        }
    }

    var symbolName: String {
        switch self {
        case .cockpit: "rectangle.inset.filled.and.person.filled"
        case .correction: "viewfinder"
        case .review: "clock.arrow.circlepath"
        case .recovery: "cross.case"
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case live
    case digital

    var id: String { rawValue }
    var title: String { self == .live ? "实时预览" : "数字棋盘" }
}

enum ControlMode: String, CaseIterable, Identifiable {
    case assist
    case confirm
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assist: "辅助"
        case .confirm: "确认"
        case .automatic: "自动"
        }
    }

    var detail: String {
        switch self {
        case .assist: "只显示建议，不操作窗口"
        case .confirm: "确认后再执行拟落点"
        case .automatic: "校验通过后自动执行"
        }
    }
}

enum PilotPhase: Int, CaseIterable, Identifiable {
    case observing
    case recognizing
    case thinking
    case previewing
    case acting
    case verifying

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .observing: "观察"
        case .recognizing: "识别"
        case .thinking: "思考"
        case .previewing: "预览"
        case .acting: "落子"
        case .verifying: "校验"
        }
    }

    var symbolName: String {
        switch self {
        case .observing: "eye"
        case .recognizing: "viewfinder"
        case .thinking: "cpu"
        case .previewing: "scope"
        case .acting: "cursorarrow.click.2"
        case .verifying: "checkmark.shield"
        }
    }
}

// MARK: - Xiangqi board presentation

enum XiangqiSide: String, Hashable {
    case red
    case black

    var title: String { self == .red ? "红方" : "黑方" }
}

struct BoardCoordinate: Hashable {
    let column: Int
    let row: Int
}

struct BoardPiece: Identifiable, Hashable {
    let id: String
    let side: XiangqiSide
    let character: String
    var coordinate: BoardCoordinate

    init(side: XiangqiSide, character: String, column: Int, row: Int) {
        id = "\(side.rawValue)-\(character)-\(column)-\(row)"
        self.side = side
        self.character = character
        coordinate = BoardCoordinate(column: column, row: row)
    }
}

struct CandidateMove: Identifiable, Hashable {
    let id: String
    let notation: String
    let origin: BoardCoordinate
    let target: BoardCoordinate
    let score: Int
    let evaluation: String
    let reason: String
}

// MARK: - Sources and activity

enum EngineSource: String, CaseIterable, Identifiable {
    case local
    case ucci

    var id: String { rawValue }
    var title: String { self == .local ? "内置快速引擎" : "Pikafish 强力引擎" }
}

enum ModelSource: String, CaseIterable, Identifiable {
    case off
    case local
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .local: "本地大模型"
        case .cloud: "云端大模型"
        }
    }
}

struct WindowSource: Identifiable, Hashable {
    let id: String
    let applicationName: String
    let windowTitle: String
    let isLocked: Bool
}

enum TimelineTone: String {
    case neutral
    case success
    case attention
    case danger
}

struct TimelineEvent: Identifiable, Hashable {
    let id: String
    let time: String
    let title: String
    let detail: String
    let symbolName: String
    let tone: TimelineTone
}

enum PositionRecoverySource: String, Hashable {
    case localVision = "本地视觉"
    case qwenFlash = "千问3.6 Flash"
    case qwenPlus = "千问3.7 Plus"
    case localAndAI = "本地视觉 + 千问"
    case dualAI = "千问双模型一致"
    case manual = "人工确认"
}

struct PositionRecoveryDifference: Identifiable, Hashable {
    let coordinate: BoardCoordinate
    let trustedPiece: BoardPiece?
    let observedPiece: BoardPiece?

    var id: String { "\(coordinate.column)-\(coordinate.row)" }

    var detail: String {
        let old = trustedPiece.map { "\($0.side.title)\($0.character)" } ?? "空位"
        let new = observedPiece.map { "\($0.side.title)\($0.character)" } ?? "空位"
        return "\(coordinate.column + 1)路 · \(coordinate.row + 1)行：\(old) → \(new)"
    }
}

// MARK: - Pure UI state

final class PilotPresentationModel: ObservableObject {
    @Published var selectedGame: GameKind
    @Published var activeWorkspace: WorkspaceDestination
    @Published var previewMode: PreviewMode
    @Published var phase: PilotPhase
    @Published var controlMode: ControlMode {
        didSet {
            guard controlMode != oldValue else { return }
            onControlModeChanged?(controlMode)
        }
    }
    @Published var engineSource: EngineSource {
        didSet {
            guard engineSource != oldValue else { return }
            onEngineSourceChanged?(engineSource)
        }
    }
    @Published var modelSource: ModelSource
    @Published var selectedCandidateID: String
    @Published var confidence: Double
    @Published var confidenceBasis: String
    @Published var isPositionTrusted: Bool
    @Published var gridDeviationPixels: Double?
    @Published var lastModelBilling: ModelCallBilling?
    @Published var modelSessionCostCNY: Double
    @Published var isPaused: Bool
    @Published var isEmergencyStopped: Bool
    @Published var events: [TimelineEvent]

    @Published var source: WindowSource
    @Published var pieces: [BoardPiece]
    @Published var sideToMove: XiangqiSide
    @Published var candidates: [CandidateMove]
    @Published var liveImage: NSImage?
    @Published var recoveryNeedsAttention = false
    @Published var isRecovering = false
    @Published var recoveryReason = "尚未检测到异常"
    @Published var recoveryDetectedAt: Date?
    @Published var lastTrustedPieceCount = 0
    @Published var recoveryCandidatePieceCount: Int?
    @Published var recoveryDifferences: [PositionRecoveryDifference] = []
    @Published var recoveryConfidence: Double?
    @Published var recoverySource: PositionRecoverySource?
    @Published var recoveryCanAutoApply = false
    @Published var recoveryHasCandidate = false
    @Published var recoveryCandidatePieces: [BoardPiece] = []
    @Published var recoveryCandidateSideToMove: XiangqiSide?
    @Published var recoveryProgressText = "等待恢复任务"

    var onPauseChanged: ((Bool) -> Void)?
    var onEmergencyStop: (() -> Void)?
    var onResumeAfterStop: (() -> Void)?
    var onRecognizePosition: (() -> Void)?
    var onApplyCorrection: (() -> Void)?
    var onConfirmMove: ((CandidateMove) -> Void)?
    var onControlModeChanged: ((ControlMode) -> Void)?
    var onRecover: (() -> Void)?
    var onBeginRecovery: (() -> Void)?
    var onApplyRecoveryCandidate: (() -> Void)?
    var onDiscardRecoveryCandidate: (() -> Void)?
    var onEngineSourceChanged: ((EngineSource) -> Void)?
    var onEditPiece: ((BoardCoordinate, XiangqiSide?, String?) -> Void)?

    var selectedCandidate: CandidateMove {
        candidates.first(where: { $0.id == selectedCandidateID }) ?? candidates.first ?? .unavailable
    }

    var headlineStatus: String {
        if isEmergencyStopped { return "已急停，所有操作已锁定" }
        if isPaused { return "对局已暂停" }

        return switch phase {
        case .observing: "正在观察棋盘"
        case .recognizing: "正在识别当前局面"
        case .thinking: "引擎正在思考"
        case .previewing: controlMode == .confirm ? "等待确认拟落点" : "拟落点已就绪"
        case .acting: "正在执行落子"
        case .verifying: "正在校验画面变化"
        }
    }

    var confidenceText: String {
        confidence.formatted(.percent.precision(.fractionLength(1)))
    }

    init(
        selectedGame: GameKind = .xiangqi,
        activeWorkspace: WorkspaceDestination = .cockpit,
        previewMode: PreviewMode = .live,
        phase: PilotPhase = .previewing,
        controlMode: ControlMode = .confirm,
        engineSource: EngineSource = .ucci,
        modelSource: ModelSource = .off,
        selectedCandidateID: String = "cannon-center",
        confidence: Double = 0.987,
        confidenceBasis: String = "尚未识别",
        isPositionTrusted: Bool = false,
        gridDeviationPixels: Double? = nil,
        lastModelBilling: ModelCallBilling? = nil,
        modelSessionCostCNY: Double = 0,
        isPaused: Bool = false,
        isEmergencyStopped: Bool = false,
        source: WindowSource,
        pieces: [BoardPiece],
        sideToMove: XiangqiSide = .red,
        candidates: [CandidateMove],
        events: [TimelineEvent],
        liveImage: NSImage? = nil
    ) {
        self.selectedGame = selectedGame
        self.activeWorkspace = activeWorkspace
        self.previewMode = previewMode
        self.phase = phase
        self.controlMode = controlMode
        self.engineSource = engineSource
        self.modelSource = modelSource
        self.selectedCandidateID = selectedCandidateID
        self.confidence = confidence
        self.confidenceBasis = confidenceBasis
        self.isPositionTrusted = isPositionTrusted
        self.gridDeviationPixels = gridDeviationPixels
        self.lastModelBilling = lastModelBilling
        self.modelSessionCostCNY = modelSessionCostCNY
        self.isPaused = isPaused
        self.isEmergencyStopped = isEmergencyStopped
        self.source = source
        self.pieces = pieces
        self.sideToMove = sideToMove
        self.candidates = candidates
        self.events = events
        self.liveImage = liveImage
    }

    func chooseCandidate(_ candidate: CandidateMove) {
        selectedCandidateID = candidate.id
        phase = .previewing
        recordEvent(
            title: "已切换候选着法",
            detail: "拟落点更新为 \(candidate.notation)",
            symbolName: "arrow.triangle.swap",
            tone: .neutral
        )
    }

    func togglePause() {
        guard !isEmergencyStopped else { return }
        isPaused.toggle()
        recordEvent(
            title: isPaused ? "已暂停" : "继续对局",
            detail: isPaused ? "视觉观察继续，窗口操作已锁定" : "重新校验后恢复控制",
            symbolName: isPaused ? "pause.fill" : "play.fill",
            tone: isPaused ? .attention : .success
        )
        onPauseChanged?(isPaused)
    }

    func emergencyStop() {
        isEmergencyStopped = true
        isPaused = true
        recordEvent(
            title: "执行紧急停止",
            detail: "已取消拟落点并锁定全部窗口操作",
            symbolName: "octagon.fill",
            tone: .danger
        )
        onEmergencyStop?()
    }

    func resumeAfterStop() {
        isEmergencyStopped = false
        isPaused = true
        phase = .recognizing
        recordEvent(
            title: "已解除急停",
            detail: "请重新识别局面后手动继续",
            symbolName: "lock.open.fill",
            tone: .attention
        )
        onResumeAfterStop?()
    }

    func recognizePosition() {
        guard !isEmergencyStopped else { return }
        if let onRecognizePosition {
            phase = .recognizing
            onRecognizePosition()
            return
        }
        phase = .recognizing
        confidence = 0.992
        recordEvent(
            title: "完成任意局面识别",
            detail: "识别到 \(pieces.count) 枚棋子 · 红方走",
            symbolName: "viewfinder.circle.fill",
            tone: .success
        )
        phase = .previewing
    }

    func applyCorrection() {
        confidence = 0.998
        phase = .thinking
        recordEvent(
            title: "人工校正已应用",
            detail: "当前局面已设为新的可信基准",
            symbolName: "checkmark.seal.fill",
            tone: .success
        )
        phase = .previewing
        onApplyCorrection?()
    }

    func editPiece(at coordinate: BoardCoordinate, token: String) {
        let side: XiangqiSide?
        let glyph: String?
        if token == "擦除" {
            side = nil
            glyph = nil
        } else {
            side = token.hasPrefix("红") ? .red : .black
            glyph = token.split(separator: "·").last.map(String.init)
        }
        if let onEditPiece {
            onEditPiece(coordinate, side, glyph)
        } else {
            pieces.removeAll { $0.coordinate == coordinate }
            if let side, let glyph {
                pieces.append(BoardPiece(side: side, character: glyph, column: coordinate.column, row: coordinate.row))
            }
        }
    }

    func confirmSelectedMove() {
        guard !isPaused, !isEmergencyStopped else { return }
        guard phase == .previewing else { return }
        guard selectedCandidate.id != CandidateMove.unavailable.id else { return }
        phase = .acting
        recordEvent(
            title: "准备执行 \(selectedCandidate.notation)",
            detail: "正在激活并复核锁定窗口，尚未发送点击",
            symbolName: "cursorarrow.click.2",
            tone: .attention
        )
        phase = .verifying
        onConfirmMove?(selectedCandidate)
    }

    func markRecovered() {
        guard recoveryHasCandidate else { return }
        onApplyRecoveryCandidate?()
    }

    func beginRecovery() {
        guard !isRecovering else { return }
        onBeginRecovery?()
    }

    func discardRecovery() {
        onDiscardRecoveryCandidate?()
    }

    func recordEvent(
        title: String,
        detail: String,
        symbolName: String,
        tone: TimelineTone
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.insert(
            TimelineEvent(
                id: UUID().uuidString,
                time: formatter.string(from: Date()),
                title: title,
                detail: detail,
                symbolName: symbolName,
                tone: tone
            ),
            at: 0
        )
    }

    func recordModelBilling(_ billing: ModelCallBilling) {
        lastModelBilling = billing
        modelSessionCostCNY += billing.costCNY
        recordEvent(
            title: "大模型识别完成",
            detail: "\(billing.modelID) · \(billing.inputTokens)+\(billing.outputTokens) Token · ¥\(billing.costCNY.formatted(.number.precision(.fractionLength(6))))",
            symbolName: "sparkles",
            tone: .neutral
        )
    }
}

extension CandidateMove {
    static let unavailable = CandidateMove(
        id: "no-legal-move",
        notation: "暂无候选",
        origin: BoardCoordinate(column: 0, row: 0),
        target: BoardCoordinate(column: 0, row: 0),
        score: 0,
        evaluation: "--",
        reason: "请先识别并确认当前局面"
    )
}

extension PilotPresentationModel {
    static var mock: PilotPresentationModel {
        PilotPresentationModel(
            source: WindowSource(
                id: "demo-xiangqi-window",
                applicationName: "象棋对局",
                windowTitle: "友谊局 · 第 1 台",
                isLocked: true
            ),
            pieces: Self.startingPieces,
            candidates: [
                CandidateMove(
                    id: "cannon-center",
                    notation: "炮二平五",
                    origin: BoardCoordinate(column: 7, row: 7),
                    target: BoardCoordinate(column: 4, row: 7),
                    score: 46,
                    evaluation: "+0.32",
                    reason: "抢占中路，保持先手压力"
                ),
                CandidateMove(
                    id: "horse-seven",
                    notation: "马八进七",
                    origin: BoardCoordinate(column: 1, row: 9),
                    target: BoardCoordinate(column: 2, row: 7),
                    score: 32,
                    evaluation: "+0.18",
                    reason: "稳健出子，保护中兵"
                ),
                CandidateMove(
                    id: "pawn-three",
                    notation: "兵三进一",
                    origin: BoardCoordinate(column: 6, row: 6),
                    target: BoardCoordinate(column: 6, row: 5),
                    score: 22,
                    evaluation: "+0.06",
                    reason: "为右马留出活动空间"
                )
            ],
            events: [
                TimelineEvent(
                    id: "event-preview",
                    time: "19:42:18",
                    title: "拟落点已生成",
                    detail: "炮二平五 · 等待确认",
                    symbolName: "scope",
                    tone: .attention
                ),
                TimelineEvent(
                    id: "event-engine",
                    time: "19:42:17",
                    title: "引擎完成思考",
                    detail: "3 个候选 · 计算 0.8 秒",
                    symbolName: "cpu.fill",
                    tone: .neutral
                ),
                TimelineEvent(
                    id: "event-recognition",
                    time: "19:42:16",
                    title: "局面识别可信",
                    detail: "32 枚棋子 · 红方走",
                    symbolName: "checkmark.seal.fill",
                    tone: .success
                ),
                TimelineEvent(
                    id: "event-window",
                    time: "19:42:15",
                    title: "目标窗口已锁定",
                    detail: "象棋对局 · 1920 × 1080",
                    symbolName: "macwindow.badge.plus",
                    tone: .neutral
                )
            ]
        )
    }

    private static var startingPieces: [BoardPiece] {
        [
            BoardPiece(side: .black, character: "車", column: 0, row: 0),
            BoardPiece(side: .black, character: "馬", column: 1, row: 0),
            BoardPiece(side: .black, character: "象", column: 2, row: 0),
            BoardPiece(side: .black, character: "士", column: 3, row: 0),
            BoardPiece(side: .black, character: "將", column: 4, row: 0),
            BoardPiece(side: .black, character: "士", column: 5, row: 0),
            BoardPiece(side: .black, character: "象", column: 6, row: 0),
            BoardPiece(side: .black, character: "馬", column: 7, row: 0),
            BoardPiece(side: .black, character: "車", column: 8, row: 0),
            BoardPiece(side: .black, character: "砲", column: 1, row: 2),
            BoardPiece(side: .black, character: "砲", column: 7, row: 2),
            BoardPiece(side: .black, character: "卒", column: 0, row: 3),
            BoardPiece(side: .black, character: "卒", column: 2, row: 3),
            BoardPiece(side: .black, character: "卒", column: 4, row: 3),
            BoardPiece(side: .black, character: "卒", column: 6, row: 3),
            BoardPiece(side: .black, character: "卒", column: 8, row: 3),
            BoardPiece(side: .red, character: "兵", column: 0, row: 6),
            BoardPiece(side: .red, character: "兵", column: 2, row: 6),
            BoardPiece(side: .red, character: "兵", column: 4, row: 6),
            BoardPiece(side: .red, character: "兵", column: 6, row: 6),
            BoardPiece(side: .red, character: "兵", column: 8, row: 6),
            BoardPiece(side: .red, character: "炮", column: 1, row: 7),
            BoardPiece(side: .red, character: "炮", column: 7, row: 7),
            BoardPiece(side: .red, character: "車", column: 0, row: 9),
            BoardPiece(side: .red, character: "馬", column: 1, row: 9),
            BoardPiece(side: .red, character: "相", column: 2, row: 9),
            BoardPiece(side: .red, character: "仕", column: 3, row: 9),
            BoardPiece(side: .red, character: "帥", column: 4, row: 9),
            BoardPiece(side: .red, character: "仕", column: 5, row: 9),
            BoardPiece(side: .red, character: "相", column: 6, row: 9),
            BoardPiece(side: .red, character: "馬", column: 7, row: 9),
            BoardPiece(side: .red, character: "車", column: 8, row: 9)
        ]
    }
}
