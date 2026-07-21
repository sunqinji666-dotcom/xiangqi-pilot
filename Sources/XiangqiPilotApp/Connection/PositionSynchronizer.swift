import Foundation
import XiangqiCore

enum PositionSynchronizationResult: Equatable, Sendable {
    case unchanged
    case confirmed(move: Move, position: Position)
    case rejected(reason: String)
}

/// Stateless rules boundary between the visual hot path and a published FEN.
/// It accepts exactly one legal two-endpoint transition and nothing else.
enum PositionSynchronizer {
    static func synchronize(
        trusted: Position,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange
    ) -> PositionSynchronizationResult {
        switch RecognitionTransitionPolicy.decide(
            trusted: trusted,
            orientation: orientation,
            visualChange: visualChange
        ) {
        case .unchanged:
            return .unchanged
        case let .legalMove(move):
            guard let next = try? trusted.applying(move) else {
                return .rejected(reason: "候选走法未能通过本地棋规")
            }
            do {
                try XiangqiPieceInventoryPolicy.validateTransition(
                    before: trusted,
                    move: move,
                    after: next
                )
            } catch {
                return .rejected(reason: error.localizedDescription)
            }
            return .confirmed(move: move, position: next)
        case .rejected:
            return .rejected(reason: "变化交点不构成唯一合法象棋着法")
        }
    }
}
