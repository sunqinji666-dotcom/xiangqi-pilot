public enum PositionStatus: Equatable, Sendable {
    case ongoing
    case check(side: Side)
    case checkmate(loser: Side, winner: Side)
    /// In Xiangqi, a side with no legal move loses even when it is not in check.
    case stalemate(loser: Side, winner: Side)
    case generalCaptured(loser: Side, winner: Side)
}

public struct PositionKey: Hashable, Sendable {
    public let boardPlacement: String
    public let sideToMove: Side

    public init(boardPlacement: String, sideToMove: Side) {
        self.boardPlacement = boardPlacement
        self.sideToMove = sideToMove
    }
}

public struct Position: Equatable, Sendable {
    public private(set) var board: Board
    public private(set) var sideToMove: Side
    public private(set) var halfmoveClock: Int
    public private(set) var fullmoveNumber: Int

    public init(
        board: Board,
        sideToMove: Side = .red,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        precondition(halfmoveClock >= 0, "Halfmove clock cannot be negative")
        precondition(fullmoveNumber >= 1, "Fullmove number must be at least one")
        self.board = board
        self.sideToMove = sideToMove
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    public static var standard: Position {
        Position(board: .standard, sideToMove: .red)
    }

    public var key: PositionKey {
        PositionKey(boardPlacement: board.fenPlacement, sideToMove: sideToMove)
    }

    public var legalMoves: [Move] {
        board.legalMoves(for: sideToMove)
    }

    public var isInCheck: Bool {
        board.isInCheck(sideToMove)
    }

    public var status: PositionStatus {
        if board.generalSquare(for: sideToMove) == nil {
            return .generalCaptured(loser: sideToMove, winner: sideToMove.opponent)
        }
        if board.generalSquare(for: sideToMove.opponent) == nil {
            return .generalCaptured(loser: sideToMove.opponent, winner: sideToMove)
        }

        let moves = legalMoves
        if moves.isEmpty {
            if isInCheck {
                return .checkmate(loser: sideToMove, winner: sideToMove.opponent)
            }
            return .stalemate(loser: sideToMove, winner: sideToMove.opponent)
        }
        return isInCheck ? .check(side: sideToMove) : .ongoing
    }

    public func applying(_ move: Move) throws -> Position {
        guard let piece = board[move.from] else {
            throw XiangqiError.noPieceAtSource(move.from)
        }
        guard piece.side == sideToMove else {
            throw XiangqiError.wrongSide(expected: sideToMove, actual: piece.side)
        }
        guard board.isLegal(move, for: sideToMove) else {
            throw XiangqiError.illegalMove(move)
        }
        return applyingKnownLegal(move)
    }

    internal func applyingKnownLegal(_ move: Move) -> Position {
        let movingPiece = board[move.from]!
        let isCapture = board[move.to] != nil
        let nextHalfmove = isCapture || movingPiece.kind == .soldier ? 0 : halfmoveClock + 1
        let nextFullmove = sideToMove == .black ? fullmoveNumber + 1 : fullmoveNumber
        return Position(
            board: board.applyingUnchecked(move),
            sideToMove: sideToMove.opponent,
            halfmoveClock: nextHalfmove,
            fullmoveNumber: nextFullmove
        )
    }
}

extension Board {
    public var fenPlacement: String {
        var ranks: [String] = []
        ranks.reserveCapacity(Self.height)
        for rank in 0..<Self.height {
            var text = ""
            var emptyCount = 0
            for file in 0..<Self.width {
                if let piece = self[Square(file: file, rank: rank)] {
                    if emptyCount > 0 {
                        text += String(emptyCount)
                        emptyCount = 0
                    }
                    text.append(piece.fenCharacter)
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 { text += String(emptyCount) }
            ranks.append(text)
        }
        return ranks.joined(separator: "/")
    }

    internal init(fenPlacement: String) throws {
        let ranks = fenPlacement.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == Self.height else {
            throw XiangqiError.invalidFEN("expected 10 ranks")
        }

        self.init()
        var generalCounts: [Side: Int] = [.red: 0, .black: 0]
        for (rank, encodedRank) in ranks.enumerated() {
            var file = 0
            for character in encodedRank {
                if let emptyCount = character.wholeNumberValue {
                    guard emptyCount > 0 else {
                        throw XiangqiError.invalidFEN("zero is not a valid empty run")
                    }
                    file += emptyCount
                } else {
                    guard file < Self.width, let piece = Piece(fenCharacter: character) else {
                        throw XiangqiError.invalidFEN("unknown piece or rank overflow at rank \(rank)")
                    }
                    let square = Square(file: file, rank: rank)
                    self[square] = piece
                    if piece.kind == .general {
                        generalCounts[piece.side, default: 0] += 1
                    }
                    file += 1
                }
                guard file <= Self.width else {
                    throw XiangqiError.invalidFEN("rank \(rank) has more than 9 files")
                }
            }
            guard file == Self.width else {
                throw XiangqiError.invalidFEN("rank \(rank) has \(file) files instead of 9")
            }
        }
        guard generalCounts.values.allSatisfy({ $0 <= 1 }) else {
            throw XiangqiError.invalidFEN("a side cannot have more than one general")
        }
    }
}

extension Position {
    public init(fen: String) throws {
        let fields = fen.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, fields.count <= 6 else {
            throw XiangqiError.invalidFEN("expected between 2 and 6 fields")
        }
        let board = try Board(fenPlacement: String(fields[0]))

        let side: Side
        switch fields[1].lowercased() {
        case "w", "r": side = .red
        case "b": side = .black
        default: throw XiangqiError.invalidFEN("side-to-move must be w, r, or b")
        }

        if fields.count >= 3, fields[2] != "-" {
            throw XiangqiError.invalidFEN("castling field must be -")
        }
        if fields.count >= 4, fields[3] != "-" {
            throw XiangqiError.invalidFEN("en-passant field must be -")
        }

        let halfmove: Int
        if fields.count >= 5 {
            guard let value = Int(fields[4]), value >= 0 else {
                throw XiangqiError.invalidFEN("invalid halfmove clock")
            }
            halfmove = value
        } else {
            halfmove = 0
        }

        let fullmove: Int
        if fields.count >= 6 {
            guard let value = Int(fields[5]), value >= 1 else {
                throw XiangqiError.invalidFEN("invalid fullmove number")
            }
            fullmove = value
        } else {
            fullmove = 1
        }

        self.init(
            board: board,
            sideToMove: side,
            halfmoveClock: halfmove,
            fullmoveNumber: fullmove
        )
    }

    public var fen: String {
        "\(board.fenPlacement) \(sideToMove.fenToken) - - \(halfmoveClock) \(fullmoveNumber)"
    }
}

private extension Piece {
    var fenCharacter: Character {
        let character: Character
        switch kind {
        case .general: character = "k"
        case .advisor: character = "a"
        case .elephant: character = "b"
        case .horse: character = "n"
        case .chariot: character = "r"
        case .cannon: character = "c"
        case .soldier: character = "p"
        }
        return side == .red ? Character(character.uppercased()) : character
    }

    init?(fenCharacter: Character) {
        let isRed = fenCharacter.isUppercase
        let symbol = Character(fenCharacter.lowercased())
        let kind: PieceKind
        switch symbol {
        case "k", "g": kind = .general
        case "a": kind = .advisor
        case "b", "e": kind = .elephant
        case "n", "h": kind = .horse
        case "r": kind = .chariot
        case "c": kind = .cannon
        case "p", "s": kind = .soldier
        default: return nil
        }
        self.init(side: isRed ? .red : .black, kind: kind)
    }
}
