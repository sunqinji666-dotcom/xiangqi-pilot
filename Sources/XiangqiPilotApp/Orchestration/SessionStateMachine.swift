import Foundation

enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case requestingPermissions
    case selectingWindow
    case calibrating
    case recognizing
    case waitingForTurn
    case deciding
    case awaitingConfirmation
    case executing
    case verifying
    case paused
    case recovering
    case stopped

    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .requestingPermissions: return "权限检查"
        case .selectingWindow: return "选择窗口"
        case .calibrating: return "标定棋盘"
        case .recognizing: return "识别局面"
        case .waitingForTurn: return "等待回合"
        case .deciding: return "引擎思考"
        case .awaitingConfirmation: return "等待确认"
        case .executing: return "正在落子"
        case .verifying: return "验证结果"
        case .paused: return "已暂停"
        case .recovering: return "异常恢复"
        case .stopped: return "已停止"
        }
    }
}

enum OperationMode: String, Codable, CaseIterable, Sendable {
    case assist
    case confirm
    case automatic

    var displayName: String {
        switch self {
        case .assist: return "辅助"
        case .confirm: return "每步确认"
        case .automatic: return "自动"
        }
    }
}

struct ObservedStateToken: Codable, Hashable, Sendable {
    let processIdentifier: Int32
    let windowIdentifier: UInt32
    let frameSequence: UInt64
    let windowGeometryHash: String
    let positionHash: String
}

struct ProposedAction: Codable, Identifiable, Sendable {
    let id: UUID
    let token: ObservedStateToken
    let move: String
    let confidence: Double
    let source: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        token: ObservedStateToken,
        move: String,
        confidence: Double,
        source: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.token = token
        self.move = move
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}

enum SessionPauseReason: String, Codable, Sendable {
    case userRequested
    case emergencyStop
    case humanTakeover
    case permissionLost
    case windowChanged
    case geometryChanged
    case staleFrame
    case lowConfidence
    case illegalPosition
    case engineFailure
    case modelFailure
    case verificationFailed
}

enum SessionStateError: LocalizedError, Equatable {
    case invalidTransition(SessionPhase, SessionPhase)
    case staleAction
    case actionMissing
    case notAwaitingAction

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to): return "不允许从“\(from.displayName)”进入“\(to.displayName)”"
        case .staleAction: return "候选着法已过期"
        case .actionMissing: return "没有待执行着法"
        case .notAwaitingAction: return "当前状态不允许执行着法"
        }
    }
}

actor SessionStateMachine {
    private(set) var phase: SessionPhase = .idle
    private(set) var mode: OperationMode = .confirm
    private(set) var pendingAction: ProposedAction?
    private(set) var lastTrustedToken: ObservedStateToken?
    private(set) var pauseReason: SessionPauseReason?
    private var generation: UInt64 = 0

    func setMode(_ mode: OperationMode) {
        self.mode = mode
    }

    func transition(to next: SessionPhase) throws {
        guard Self.allowedTransitions[phase, default: []].contains(next) else {
            throw SessionStateError.invalidTransition(phase, next)
        }
        phase = next
        if next != .paused { pauseReason = nil }
    }

    func acceptTrustedObservation(_ token: ObservedStateToken) {
        lastTrustedToken = token
    }

    func queue(_ action: ProposedAction) throws {
        guard phase == .deciding || phase == .recognizing else {
            throw SessionStateError.notAwaitingAction
        }
        guard action.token == lastTrustedToken else { throw SessionStateError.staleAction }
        pendingAction = action
        phase = mode == .assist ? .waitingForTurn : .awaitingConfirmation
    }

    func approvePendingAction(currentToken: ObservedStateToken) throws -> ProposedAction {
        guard phase == .awaitingConfirmation, let action = pendingAction else {
            throw SessionStateError.actionMissing
        }
        guard action.token == currentToken, currentToken == lastTrustedToken else {
            pendingAction = nil
            phase = .paused
            pauseReason = .staleFrame
            throw SessionStateError.staleAction
        }
        phase = .executing
        return action
    }

    func beginAutomaticAction(currentToken: ObservedStateToken) throws -> ProposedAction {
        guard mode == .automatic else { throw SessionStateError.notAwaitingAction }
        return try approvePendingAction(currentToken: currentToken)
    }

    func markInputSent() throws {
        guard phase == .executing else { throw SessionStateError.notAwaitingAction }
        phase = .verifying
    }

    func markVerified(newToken: ObservedStateToken) throws {
        guard phase == .verifying else { throw SessionStateError.invalidTransition(phase, .waitingForTurn) }
        pendingAction = nil
        lastTrustedToken = newToken
        phase = .waitingForTurn
    }

    func pause(_ reason: SessionPauseReason) {
        generation &+= 1
        pendingAction = nil
        phase = .paused
        pauseReason = reason
    }

    func emergencyStop() {
        generation &+= 1
        pendingAction = nil
        lastTrustedToken = nil
        phase = .stopped
        pauseReason = .emergencyStop
    }

    func resumeFromTrustedObservation(_ token: ObservedStateToken) {
        generation &+= 1
        pendingAction = nil
        lastTrustedToken = token
        pauseReason = nil
        phase = .recognizing
    }

    private static let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.requestingPermissions, .selectingWindow, .stopped],
        .requestingPermissions: [.selectingWindow, .paused, .stopped],
        .selectingWindow: [.calibrating, .paused, .stopped],
        .calibrating: [.recognizing, .paused, .stopped],
        .recognizing: [.waitingForTurn, .deciding, .awaitingConfirmation, .paused, .recovering, .stopped],
        .waitingForTurn: [.recognizing, .deciding, .paused, .recovering, .stopped],
        .deciding: [.awaitingConfirmation, .waitingForTurn, .paused, .recovering, .stopped],
        .awaitingConfirmation: [.executing, .waitingForTurn, .paused, .stopped],
        .executing: [.verifying, .paused, .stopped],
        .verifying: [.waitingForTurn, .paused, .recovering, .stopped],
        .paused: [.recognizing, .calibrating, .selectingWindow, .recovering, .stopped],
        .recovering: [.calibrating, .recognizing, .paused, .stopped],
        .stopped: [.idle, .requestingPermissions, .selectingWindow]
    ]
}
