import Foundation

public enum GomokuHeuristicEngine {
    public static func bestMove(in position: GomokuPosition) -> GridCoordinate? {
        guard position.status == .ongoing else { return nil }
        let legal = position.legalMoves
        // Rule-first tactics: win immediately, then block immediate loss.
        if let winning = legal.first(where: { (try? position.applying($0).status) == .win(position.sideToMove) }) {
            return winning
        }
        let opponentView = GomokuPosition(size: position.size, stones: position.stones, sideToMove: position.sideToMove.opponent)
        if let block = legal.first(where: { (try? opponentView.applying($0).status) == .win(position.sideToMove.opponent) }) {
            return block
        }
        let center = Double(position.size - 1) / 2
        return legal.max { lhs, rhs in
            score(lhs, in: position, center: center) < score(rhs, in: position, center: center)
        }
    }

    private static func score(_ point: GridCoordinate, in position: GomokuPosition, center: Double) -> Int {
        let distance = abs(Double(point.column) - center) + abs(Double(point.row) - center)
        var score = Int(100 - distance * 4)
        for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            for color in [position.sideToMove, position.sideToMove.opponent] {
                var count = 0
                for sign in [-1, 1] {
                    var x = point.column + sign * dx
                    var y = point.row + sign * dy
                    while position.stones[GridCoordinate(column: x, row: y)] == color { count += 1; x += sign * dx; y += sign * dy }
                }
                score += count * count * (color == position.sideToMove ? 18 : 14)
            }
        }
        return score
    }
}

public enum GoHeuristicEngine {
    public static func bestMove(in position: GoPosition) -> GoMove {
        let legal = position.legalMoves
        guard !legal.isEmpty else { return .pass }
        let center = Double(position.size - 1) / 2
        let plays = legal.compactMap { move -> (GoMove, Int)? in
            guard case let .play(point) = move, let after = try? position.applying(move) else { return nil }
            let captures = position.stones.count + 1 - after.stones.count
            let distance = abs(Double(point.column) - center) + abs(Double(point.row) - center)
            return (move, captures * 10_000 + Int(400 - distance * 12))
        }
        return plays.max(by: { $0.1 < $1.1 })?.0 ?? .pass
    }
}
