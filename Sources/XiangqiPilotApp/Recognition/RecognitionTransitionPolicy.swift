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
    static func visuallySupports(
        _ move: Move,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange
    ) -> Bool {
        let endpoints: Set<BoardCellCoordinate> = [
            visualCoordinate(for: move.from, orientation: orientation),
            visualCoordinate(for: move.to, orientation: orientation)
        ]
        return endpoints.isSubset(of: Set(visualChange.cells.map(\.coordinate)))
    }

    /// Returns the unique legal opponent reply when the caller already knows
    /// which first move it dispatched. Some target apps publish our move and
    /// the computer reply in one delayed redraw, so the intermediate board is
    /// never observable. Constraining the first ply removes the ambiguity that
    /// exists when trying to infer both moves from pixels alone.
    static func decoratedLegalReply(
        trusted: Position,
        firstMove: Move,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange,
        maximumDecorationCells: Int = 2
    ) -> Move? {
        guard trusted.legalMoves.contains(firstMove),
              let afterFirst = try? trusted.applying(firstMove) else {
            return nil
        }
        let changedScores = Dictionary(uniqueKeysWithValues: visualChange.cells)
        let changedCells = Set(changedScores.keys)
        guard changedCells.count >= 3,
              changedCells.count <= 4 + maximumDecorationCells else {
            return nil
        }
        let firstEndpoints: Set<BoardCellCoordinate> = [
            visualCoordinate(for: firstMove.from, orientation: orientation),
            visualCoordinate(for: firstMove.to, orientation: orientation)
        ]
        guard firstEndpoints.isSubset(of: changedCells) else { return nil }

        let scored = afterFirst.legalMoves.compactMap { reply -> (move: Move, score: Double)? in
            let endpoints = firstEndpoints.union([
                visualCoordinate(for: reply.from, orientation: orientation),
                visualCoordinate(for: reply.to, orientation: orientation)
            ])
            guard endpoints.count >= 3,
                  endpoints.isSubset(of: changedCells) else { return nil }
            let decorations = changedCells.subtracting(endpoints)
            guard decorations.count <= maximumDecorationCells else { return nil }
            let endpointScore = endpoints.reduce(0.0) { $0 + (changedScores[$1] ?? 0) }
            let decorationScore = decorations.reduce(0.0) { $0 + (changedScores[$1] ?? 0) }
            return (reply, endpointScore - decorationScore * 0.18)
        }.sorted { $0.score > $1.score }

        guard let best = scored.first,
              best.score > 0,
              scored.dropFirst().first.map({ best.score - $0.score >= 0.04 }) ?? true else {
            return nil
        }
        return best.move
    }

    /// Explains a stable delta spanning two consecutive plies.  This happens
    /// when the target application's move animation, foreground activation,
    /// or capture polling means we do not observe the intermediate board:
    /// our move and the opponent reply are both already visible.  We accept
    /// only a *unique* legal line whose four (or three, when endpoints
    /// overlap) visual endpoints are all present in the delta.
    static func decoratedLegalLine(
        trusted: Position,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange,
        maximumDecorationCells: Int = 2
    ) -> [Move]? {
        let changedScores = Dictionary(uniqueKeysWithValues: visualChange.cells)
        let changedCells = Set(changedScores.keys)
        guard changedCells.count >= 3,
              changedCells.count <= 4 + maximumDecorationCells else {
            return nil
        }

        let scored = trusted.legalMoves.flatMap { first -> [(line: [Move], score: Double)] in
            guard let afterFirst = try? trusted.applying(first) else { return [] }
            return afterFirst.legalMoves.compactMap { second in
                let endpoints: Set<BoardCellCoordinate> = [
                    visualCoordinate(for: first.from, orientation: orientation),
                    visualCoordinate(for: first.to, orientation: orientation),
                    visualCoordinate(for: second.from, orientation: orientation),
                    visualCoordinate(for: second.to, orientation: orientation)
                ]
                guard endpoints.count >= 3,
                      endpoints.isSubset(of: changedCells) else { return nil }
                let decorations = changedCells.subtracting(endpoints)
                guard decorations.count <= maximumDecorationCells else { return nil }
                let endpointScore = endpoints.reduce(0.0) { $0 + (changedScores[$1] ?? 0) }
                let decorationScore = decorations.reduce(0.0) { $0 + (changedScores[$1] ?? 0) }
                return ([first, second], endpointScore - decorationScore * 0.18)
            }
        }.sorted { $0.score > $1.score }

        guard let best = scored.first,
              best.score > 0,
              scored.dropFirst().first.map({ best.score - $0.score >= 0.06 }) ?? true else {
            return nil
        }
        return best.line
    }

    /// Returns a uniquely explained legal move when both endpoints have
    /// changed but the board also contains a small number of persistent UI
    /// decorations (selection rings, last-move markers, and hints).  This is
    /// deliberately separate from `decide`: callers must still collect this
    /// result across stable frames before committing it to the game state.
    static func decoratedLegalMove(
        trusted: Position,
        orientation: BoardOrientation,
        visualChange: BoardVisualChange,
        maximumDecorationCells: Int = 4
    ) -> Move? {
        let changedScores = Dictionary(uniqueKeysWithValues: visualChange.cells)
        let changedCells = Set(changedScores.keys)
        guard changedCells.count >= 2,
              changedCells.count <= 2 + maximumDecorationCells else {
            return nil
        }

        let scored = trusted.legalMoves.compactMap { move -> (move: Move, score: Double)? in
            let endpoints: Set<BoardCellCoordinate> = [
                visualCoordinate(for: move.from, orientation: orientation),
                visualCoordinate(for: move.to, orientation: orientation)
            ]
            guard endpoints.isSubset(of: changedCells),
                  let fromScore = changedScores[visualCoordinate(for: move.from, orientation: orientation)],
                  let toScore = changedScores[visualCoordinate(for: move.to, orientation: orientation)] else {
                return nil
            }
            let decorationScore = changedCells.subtracting(endpoints).reduce(0.0) {
                $0 + (changedScores[$1] ?? 0)
            }
            // Endpoint evidence must dominate decoration evidence.  This is
            // only a ranking signal; temporal confirmation remains mandatory.
            return (move, fromScore + toScore - decorationScore * 0.18)
        }.sorted { $0.score > $1.score }

        guard let best = scored.first,
              best.score > 0,
              scored.dropFirst().first.map({ best.score - $0.score >= 0.06 }) ?? true else {
            return nil
        }
        return best.move
    }

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
