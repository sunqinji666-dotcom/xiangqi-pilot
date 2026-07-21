import CoreGraphics
import Foundation
import XiangqiCore

/// User-visible lifecycle of a bound Xiangqi board.  This is deliberately
/// independent from SwiftUI's presentation phases: a client adapter, a video
/// replay, and a native app all travel through the same connection states.
enum BoardConnectionState: String, CaseIterable, Sendable {
    case disconnected
    case windowConnected
    case calibrating
    case synchronizingInitialPosition
    case observing
    case boardChanged
    case confirmingMove
    case resynchronizationRequired
    case recalibrationRequired
    case lost

    var title: String {
        switch self {
        case .disconnected: "未连线"
        case .windowConnected: "已连接窗口"
        case .calibrating: "标定棋盘"
        case .synchronizingInitialPosition: "同步首个局面"
        case .observing: "实时观察"
        case .boardChanged: "棋盘变化"
        case .confirmingMove: "解析并确认落子"
        case .resynchronizationRequired: "需要重新同步"
        case .recalibrationRequired: "需要重新标定"
        case .lost: "画面已丢失"
        }
    }
}

struct BoardConnectionSnapshot: Equatable, Sendable {
    let state: BoardConnectionState
    let targetWindowID: CGWindowID?
    let framesPerSecond: Double?
    let latestFEN: String?
    let latestMoveUCCI: String?
    let sideToMove: Side?
    let confidence: Double?
    let detail: String
}

/// The event emitted to downstream UI, engines and audit logs only after a
/// move is proved by the rules layer. It is intentionally compact and has no
/// dependence on a particular client skin.
struct BoardPositionEvent: Equatable, Sendable {
    let fen: String
    let moveUCCI: String
    let sideToMove: Side
    let confidence: Double
    let frameSequence: UInt64
}

actor BoardConnectionSession {
    private var state: BoardConnectionState = .disconnected
    private var targetWindowID: CGWindowID?
    private var latestFEN: String?
    private var latestMoveUCCI: String?
    private var sideToMove: Side?
    private var confidence: Double?
    private var lastFrameSequence: UInt64?
    private var lastPresentationTime: TimeInterval?
    private var frameIntervals: [Double] = []
    private var detail = "尚未选择窗口"

    func connect(windowID: CGWindowID) {
        targetWindowID = windowID
        latestFEN = nil
        latestMoveUCCI = nil
        sideToMove = nil
        confidence = nil
        lastFrameSequence = nil
        lastPresentationTime = nil
        frameIntervals.removeAll(keepingCapacity: true)
        state = .windowConnected
        detail = "已锁定 windowID \(windowID)"
    }

    func beginCalibration() {
        guard targetWindowID != nil else { return }
        state = .calibrating
        detail = "请标定棋盘最外侧四个交叉点"
    }

    func beginInitialSynchronization() {
        guard targetWindowID != nil else { return }
        state = .synchronizingInitialPosition
        detail = "正在建立首个规则局面"
    }

    func acceptInitialPosition(_ position: Position, confidence: Double, frameSequence: UInt64) {
        latestFEN = position.fen
        latestMoveUCCI = nil
        sideToMove = position.sideToMove
        self.confidence = confidence
        lastFrameSequence = frameSequence
        state = .observing
        detail = "首个局面已同步，正在观察棋盘"
    }

    func recordFrame(sequence: UInt64, presentationTime: TimeInterval) {
        if let previous = lastPresentationTime {
            let interval = presentationTime - previous
            if interval.isFinite, interval > 0, interval < 2 {
                frameIntervals.append(interval)
                if frameIntervals.count > 20 { frameIntervals.removeFirst() }
            }
        }
        lastPresentationTime = presentationTime
        lastFrameSequence = max(lastFrameSequence ?? 0, sequence)
    }

    func observeChange(detail: String) {
        guard state == .observing else { return }
        state = .boardChanged
        self.detail = detail
    }

    func beginMoveConfirmation() {
        guard state == .boardChanged || state == .observing else { return }
        state = .confirmingMove
        detail = "正在用棋规确认本次变化"
    }

    func acceptMove(_ event: BoardPositionEvent) {
        latestFEN = event.fen
        latestMoveUCCI = event.moveUCCI
        sideToMove = event.sideToMove
        confidence = event.confidence
        lastFrameSequence = event.frameSequence
        state = .observing
        detail = "已确认 \(event.moveUCCI)，继续实时观察"
    }

    func requireRecalibration(_ reason: String) {
        state = .recalibrationRequired
        detail = reason
    }

    func requireResynchronization(_ reason: String) {
        state = .resynchronizationRequired
        detail = reason
    }

    func markLost(_ reason: String) {
        state = .lost
        detail = reason
    }

    func disconnect() {
        state = .disconnected
        targetWindowID = nil
        latestFEN = nil
        latestMoveUCCI = nil
        sideToMove = nil
        confidence = nil
        detail = "已断开棋盘连接"
    }

    func snapshot() -> BoardConnectionSnapshot {
        let fps: Double?
        if !frameIntervals.isEmpty {
            fps = 1 / (frameIntervals.reduce(0, +) / Double(frameIntervals.count))
        } else {
            fps = nil
        }
        return BoardConnectionSnapshot(
            state: state,
            targetWindowID: targetWindowID,
            framesPerSecond: fps,
            latestFEN: latestFEN,
            latestMoveUCCI: latestMoveUCCI,
            sideToMove: sideToMove,
            confidence: confidence,
            detail: detail
        )
    }
}
