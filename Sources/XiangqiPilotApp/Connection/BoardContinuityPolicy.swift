import Foundation

enum BoardContinuityAssessment: Equatable, Sendable {
    case ordinaryTransition
    case positionJump(changedIntersections: Int)
}

/// Separates a plausible one-ply render transition from a wholesale board
/// replacement caused by replay seeking, page reload, or switching games.
/// The rules synchronizer remains the authority for ordinary transitions.
enum BoardContinuityPolicy {
    static let positionJumpThreshold = 6

    static func assess(_ change: BoardVisualChange) -> BoardContinuityAssessment {
        if change.cells.count >= positionJumpThreshold {
            return .positionJump(changedIntersections: change.cells.count)
        }
        return .ordinaryTransition
    }
}
