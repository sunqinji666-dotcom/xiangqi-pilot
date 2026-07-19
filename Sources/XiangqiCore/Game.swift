public enum GameStatus: Equatable, Sendable {
    case ongoing
    case check(side: Side)
    case checkmate(loser: Side, winner: Side)
    case stalemate(loser: Side, winner: Side)
    case generalCaptured(loser: Side, winner: Side)
    /// Repetition adjudication differs between rule sets. The core reports the
    /// count and complete move/check history so the host can apply its policy.
    case repetition(count: Int)
}

public struct MoveRecord: Equatable, Sendable {
    public let move: Move
    public let movingPiece: Piece
    public let capturedPiece: Piece?
    public let positionBefore: Position
    public let positionAfter: Position
    public let gaveCheck: Bool

    public init(
        move: Move,
        movingPiece: Piece,
        capturedPiece: Piece?,
        positionBefore: Position,
        positionAfter: Position,
        gaveCheck: Bool
    ) {
        self.move = move
        self.movingPiece = movingPiece
        self.capturedPiece = capturedPiece
        self.positionBefore = positionBefore
        self.positionAfter = positionAfter
        self.gaveCheck = gaveCheck
    }
}

public struct Game: Sendable {
    public private(set) var position: Position
    public private(set) var records: [MoveRecord]
    private var repetitionCounts: [PositionKey: Int]

    public init(position: Position = .standard) {
        self.position = position
        self.records = []
        self.repetitionCounts = [position.key: 1]
    }

    public var moveHistory: [Move] {
        records.map(\.move)
    }

    public var canUndo: Bool { !records.isEmpty }

    public var currentRepetitionCount: Int {
        repetitionCounts[position.key, default: 0]
    }

    public var isThreefoldRepetition: Bool {
        currentRepetitionCount >= 3
    }

    public var status: GameStatus {
        switch position.status {
        case .checkmate(let loser, let winner):
            return .checkmate(loser: loser, winner: winner)
        case .stalemate(let loser, let winner):
            return .stalemate(loser: loser, winner: winner)
        case .generalCaptured(let loser, let winner):
            return .generalCaptured(loser: loser, winner: winner)
        case .check(let side):
            return isThreefoldRepetition
                ? .repetition(count: currentRepetitionCount)
                : .check(side: side)
        case .ongoing:
            return isThreefoldRepetition
                ? .repetition(count: currentRepetitionCount)
                : .ongoing
        }
    }

    public func repetitionCount(for key: PositionKey) -> Int {
        repetitionCounts[key, default: 0]
    }

    @discardableResult
    public mutating func play(_ move: Move) throws -> MoveRecord {
        guard let movingPiece = position.board[move.from] else {
            throw XiangqiError.noPieceAtSource(move.from)
        }
        let capturedPiece = position.board[move.to]
        let before = position
        let after = try position.applying(move)
        let record = MoveRecord(
            move: move,
            movingPiece: movingPiece,
            capturedPiece: capturedPiece,
            positionBefore: before,
            positionAfter: after,
            gaveCheck: after.board.isInCheck(after.sideToMove)
        )
        records.append(record)
        position = after
        repetitionCounts[after.key, default: 0] += 1
        return record
    }

    @discardableResult
    public mutating func undo() -> MoveRecord? {
        guard let record = records.popLast() else { return nil }
        let currentKey = position.key
        if let count = repetitionCounts[currentKey] {
            if count <= 1 {
                repetitionCounts.removeValue(forKey: currentKey)
            } else {
                repetitionCounts[currentKey] = count - 1
            }
        }
        position = record.positionBefore
        return record
    }

    public mutating func reset(to position: Position = .standard) {
        self.position = position
        records.removeAll(keepingCapacity: true)
        repetitionCounts = [position.key: 1]
    }
}
