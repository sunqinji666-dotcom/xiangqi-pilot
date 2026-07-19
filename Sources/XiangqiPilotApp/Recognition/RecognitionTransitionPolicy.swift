import Foundation
import XiangqiCore

enum RecognitionTransitionDecision: Equatable, Sendable {
    case unchanged
    case legalMove(Move)
    case rejected
}

/// Prevents a noisy full-board OCR pass from replacing the last trusted game
/// state. Once a position is trusted, a new observation may only confirm that
/// same board or prove one unique legal move with matching visual endpoints.
enum RecognitionTransitionPolicy {
    static func decide(
        trusted: Position,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange
    ) -> RecognitionTransitionDecision {
        let changedCells = Set(visualChange.cells.map(\.coordinate))
        if changedCells.isEmpty { return .unchanged }
        guard changedCells.count == 2 else { return .rejected }

        let matchingMoves = trusted.legalMoves.filter { move in
            Set([
                visualCoordinate(for: move.from, orientation: orientation),
                visualCoordinate(for: move.to, orientation: orientation)
            ]) == changedCells
        }
        guard matchingMoves.count == 1, let move = matchingMoves.first else {
            return .rejected
        }
        return .legalMove(move)
    }

    static func decide(
        trusted: Position,
        observed: Position,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange?
    ) -> RecognitionTransitionDecision {
        if trusted.board == observed.board { return .unchanged }

        let matchingMoves = trusted.legalMoves.filter { move in
            (try? trusted.applying(move).board) == observed.board
        }
        guard matchingMoves.count == 1, let move = matchingMoves.first else {
            return .rejected
        }

        guard let visualChange else { return .rejected }
        let expectedCells: Set<BoardCellCoordinate> = [
            visualCoordinate(for: move.from, orientation: orientation),
            visualCoordinate(for: move.to, orientation: orientation)
        ]
        let changedCells = Set(visualChange.cells.map(\.coordinate))
        guard changedCells == expectedCells else { return .rejected }
        return .legalMove(move)
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
}
