import Foundation

public enum Side: String, CaseIterable, Codable, Sendable {
    case red
    case black

    public var opponent: Side {
        self == .red ? .black : .red
    }

    /// Ranks are stored from Black's side (0) to Red's side (9).
    public var forwardRankDelta: Int {
        self == .red ? -1 : 1
    }

    public var fenToken: String {
        self == .red ? "w" : "b"
    }
}

public enum PieceKind: String, CaseIterable, Codable, Sendable {
    case general
    case advisor
    case elephant
    case horse
    case chariot
    case cannon
    case soldier

    public var materialValue: Int {
        switch self {
        case .general: return 100_000
        case .chariot: return 900
        case .cannon: return 450
        case .horse: return 400
        case .advisor, .elephant: return 200
        case .soldier: return 100
        }
    }
}

public struct Piece: Hashable, Codable, Sendable {
    public let side: Side
    public let kind: PieceKind

    public init(side: Side, kind: PieceKind) {
        self.side = side
        self.kind = kind
    }
}

public struct Square: Hashable, Codable, Sendable, CustomStringConvertible {
    public let file: Int
    public let rank: Int

    public init(file: Int, rank: Int) {
        precondition(Self.isValid(file: file, rank: rank), "Xiangqi square is outside the 9x10 board")
        self.file = file
        self.rank = rank
    }

    public static func isValid(file: Int, rank: Int) -> Bool {
        (0..<Board.width).contains(file) && (0..<Board.height).contains(rank)
    }

    /// UCCI notation uses a0 at Red's lower-left corner and a9 at Black's.
    public init?(ucci: String) {
        let characters = Array(ucci.lowercased())
        guard characters.count == 2,
              let fileScalar = characters[0].unicodeScalars.first,
              let rank = characters[1].wholeNumberValue else {
            return nil
        }
        let file = Int(fileScalar.value) - Int(UnicodeScalar("a").value)
        let internalRank = 9 - rank
        guard Self.isValid(file: file, rank: internalRank) else {
            return nil
        }
        self.init(file: file, rank: internalRank)
    }

    public var ucci: String {
        let scalar = UnicodeScalar(Int(UnicodeScalar("a").value) + file)!
        return "\(Character(scalar))\(9 - rank)"
    }

    public var description: String { ucci }
}

public struct Move: Hashable, Codable, Sendable, CustomStringConvertible {
    public let from: Square
    public let to: Square

    public init(from: Square, to: Square) {
        self.from = from
        self.to = to
    }

    public init?(ucci: String) {
        let characters = Array(ucci)
        guard characters.count == 4,
              let from = Square(ucci: String(characters[0...1])),
              let to = Square(ucci: String(characters[2...3])) else {
            return nil
        }
        self.init(from: from, to: to)
    }

    public var ucci: String { from.ucci + to.ucci }
    public var description: String { ucci }
}

public struct Placement: Hashable, Codable, Sendable {
    public let square: Square
    public let piece: Piece

    public init(_ piece: Piece, at square: Square) {
        self.square = square
        self.piece = piece
    }
}

public enum XiangqiError: Error, Equatable, Sendable {
    case invalidFEN(String)
    case duplicatePlacement(Square)
    case noPieceAtSource(Square)
    case wrongSide(expected: Side, actual: Side)
    case illegalMove(Move)
}

extension XiangqiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFEN(let reason):
            return "Invalid Xiangqi FEN: \(reason)"
        case .duplicatePlacement(let square):
            return "More than one piece was placed on \(square)."
        case .noPieceAtSource(let square):
            return "There is no piece on \(square)."
        case .wrongSide(let expected, let actual):
            return "It is \(expected.rawValue)'s turn, not \(actual.rawValue)'s."
        case .illegalMove(let move):
            return "Move \(move) is illegal."
        }
    }
}
