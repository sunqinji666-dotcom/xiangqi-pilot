import Foundation

/// Shared coordinate type for the 15×15 Gomoku and 9/13/19-line Go boards.
public struct GridCoordinate: Hashable, Sendable, Comparable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public static func < (lhs: GridCoordinate, rhs: GridCoordinate) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

public enum GridStone: String, CaseIterable, Sendable {
    case black
    case white

    public var opponent: GridStone { self == .black ? .white : .black }
}

public enum GomokuStatus: Equatable, Sendable {
    case ongoing
    case win(GridStone)
    case draw
}

public enum GomokuError: LocalizedError, Equatable {
    case outOfBounds
    case occupied
    case gameOver

    public var errorDescription: String? {
        switch self {
        case .outOfBounds: "落点不在棋盘内"
        case .occupied: "该交点已有棋子"
        case .gameOver: "本局已结束"
        }
    }
}

/// Freestyle Gomoku: the first side with five or more consecutive stones wins.
public struct GomokuPosition: Equatable, Sendable {
    public let size: Int
    public private(set) var stones: [GridCoordinate: GridStone]
    public private(set) var sideToMove: GridStone
    public private(set) var status: GomokuStatus

    public init(size: Int = 15, stones: [GridCoordinate: GridStone] = [:], sideToMove: GridStone = .black) {
        precondition((9...19).contains(size), "Gomoku board must be 9…19")
        self.size = size
        self.stones = stones
        self.sideToMove = sideToMove
        self.status = Self.status(size: size, stones: stones)
    }

    public var legalMoves: [GridCoordinate] {
        guard status == .ongoing else { return [] }
        return (0..<size).flatMap { row in
            (0..<size).compactMap { column in
                let point = GridCoordinate(column: column, row: row)
                return stones[point] == nil ? point : nil
            }
        }
    }

    public func applying(_ coordinate: GridCoordinate) throws -> GomokuPosition {
        guard status == .ongoing else { throw GomokuError.gameOver }
        guard contains(coordinate) else { throw GomokuError.outOfBounds }
        guard stones[coordinate] == nil else { throw GomokuError.occupied }
        var next = stones
        next[coordinate] = sideToMove
        return GomokuPosition(size: size, stones: next, sideToMove: sideToMove.opponent)
    }

    public func contains(_ coordinate: GridCoordinate) -> Bool {
        (0..<size).contains(coordinate.column) && (0..<size).contains(coordinate.row)
    }

    private static func status(size: Int, stones: [GridCoordinate: GridStone]) -> GomokuStatus {
        let directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
        for (point, stone) in stones {
            for (dx, dy) in directions where lineLength(from: point, stone: stone, dx: dx, dy: dy, size: size, stones: stones) >= 5 {
                return .win(stone)
            }
        }
        return stones.count == size * size ? .draw : .ongoing
    }

    private static func lineLength(
        from point: GridCoordinate,
        stone: GridStone,
        dx: Int,
        dy: Int,
        size: Int,
        stones: [GridCoordinate: GridStone]
    ) -> Int {
        var count = 1
        for sign in [-1, 1] {
            var column = point.column + sign * dx
            var row = point.row + sign * dy
            while (0..<size).contains(column), (0..<size).contains(row),
                  stones[GridCoordinate(column: column, row: row)] == stone {
                count += 1
                column += sign * dx
                row += sign * dy
            }
        }
        return count
    }
}

public enum GoMove: Hashable, Sendable {
    case play(GridCoordinate)
    case pass
}

public enum GoStatus: Equatable, Sendable {
    case ongoing
    case finished(blackScore: Int, whiteScore: Int)
}

public enum GoError: LocalizedError, Equatable {
    case outOfBounds
    case occupied
    case suicide
    case ko
    case gameOver

    public var errorDescription: String? {
        switch self {
        case .outOfBounds: "落点不在棋盘内"
        case .occupied: "该交点已有棋子"
        case .suicide: "禁止自杀"
        case .ko: "简单劫禁止立即还原局面"
        case .gameOver: "本局已结束"
        }
    }
}

/// Compact rules core for Chinese rules practice boards.  It enforces capture,
/// suicide and simple-ko; score is area score (stones + surrounded empty points).
public struct GoPosition: Equatable, Sendable {
    public let size: Int
    public private(set) var stones: [GridCoordinate: GridStone]
    public private(set) var sideToMove: GridStone
    public private(set) var consecutivePasses: Int
    public private(set) var status: GoStatus
    private var previousBoardKey: String?

    public init(
        size: Int = 19,
        stones: [GridCoordinate: GridStone] = [:],
        sideToMove: GridStone = .black,
        consecutivePasses: Int = 0,
        previousBoardKey: String? = nil
    ) {
        precondition([9, 13, 19].contains(size), "Go board must be 9, 13, or 19")
        self.size = size
        self.stones = stones
        self.sideToMove = sideToMove
        self.consecutivePasses = consecutivePasses
        self.previousBoardKey = previousBoardKey
        self.status = consecutivePasses >= 2 ? Self.finishedScore(size: size, stones: stones) : .ongoing
    }

    public var legalMoves: [GoMove] {
        guard status == .ongoing else { return [] }
        let points = (0..<size).flatMap { row in
            (0..<size).compactMap { column -> GoMove? in
                let point = GridCoordinate(column: column, row: row)
                return (try? applying(.play(point))) == nil ? nil : .play(point)
            }
        }
        return points + [.pass]
    }

    public func applying(_ move: GoMove) throws -> GoPosition {
        guard status == .ongoing else { throw GoError.gameOver }
        switch move {
        case .pass:
            return GoPosition(
                size: size,
                stones: stones,
                sideToMove: sideToMove.opponent,
                consecutivePasses: consecutivePasses + 1,
                previousBoardKey: boardKey(stones)
            )
        case let .play(point):
            guard contains(point) else { throw GoError.outOfBounds }
            guard stones[point] == nil else { throw GoError.occupied }
            var next = stones
            next[point] = sideToMove
            for neighbor in neighbors(of: point) where next[neighbor] == sideToMove.opponent {
                let group = group(at: neighbor, in: next)
                if liberties(of: group, in: next).isEmpty {
                    for captured in group { next[captured] = nil }
                }
            }
            let own = group(at: point, in: next)
            guard !liberties(of: own, in: next).isEmpty else { throw GoError.suicide }
            let key = boardKey(next)
            guard key != previousBoardKey else { throw GoError.ko }
            return GoPosition(
                size: size,
                stones: next,
                sideToMove: sideToMove.opponent,
                consecutivePasses: 0,
                previousBoardKey: boardKey(stones)
            )
        }
    }

    public func contains(_ coordinate: GridCoordinate) -> Bool {
        (0..<size).contains(coordinate.column) && (0..<size).contains(coordinate.row)
    }

    private func neighbors(of point: GridCoordinate) -> [GridCoordinate] {
        [(0, -1), (1, 0), (0, 1), (-1, 0)].compactMap { dx, dy in
            let candidate = GridCoordinate(column: point.column + dx, row: point.row + dy)
            return contains(candidate) ? candidate : nil
        }
    }

    private func group(at origin: GridCoordinate, in board: [GridCoordinate: GridStone]) -> Set<GridCoordinate> {
        guard let color = board[origin] else { return [] }
        var result: Set<GridCoordinate> = [origin]
        var frontier = [origin]
        while let point = frontier.popLast() {
            for neighbor in neighbors(of: point) where board[neighbor] == color && result.insert(neighbor).inserted {
                frontier.append(neighbor)
            }
        }
        return result
    }

    private func liberties(of group: Set<GridCoordinate>, in board: [GridCoordinate: GridStone]) -> Set<GridCoordinate> {
        Set(group.flatMap { point in neighbors(of: point).filter { board[$0] == nil } })
    }

    private func boardKey(_ board: [GridCoordinate: GridStone]) -> String {
        board.sorted { $0.key < $1.key }.map { "\($0.key.column),\($0.key.row),\($0.value.rawValue)" }.joined(separator: ";")
    }

    private static func finishedScore(size: Int, stones: [GridCoordinate: GridStone]) -> GoStatus {
        var black = stones.values.filter { $0 == .black }.count
        var white = stones.values.filter { $0 == .white }.count
        var visited: Set<GridCoordinate> = []
        for row in 0..<size {
            for column in 0..<size {
                let start = GridCoordinate(column: column, row: row)
                guard stones[start] == nil, visited.insert(start).inserted else { continue }
                var region: Set<GridCoordinate> = [start]
                var frontier = [start]
                var borders: Set<GridStone> = []
                while let point = frontier.popLast() {
                    for (dx, dy) in [(0, -1), (1, 0), (0, 1), (-1, 0)] {
                        let next = GridCoordinate(column: point.column + dx, row: point.row + dy)
                        guard (0..<size).contains(next.column), (0..<size).contains(next.row) else { continue }
                        if let color = stones[next] { borders.insert(color) }
                        else if visited.insert(next).inserted { region.insert(next); frontier.append(next) }
                    }
                }
                if borders == [.black] { black += region.count }
                if borders == [.white] { white += region.count }
            }
        }
        return .finished(blackScore: black, whiteScore: white)
    }
}
