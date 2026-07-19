import Foundation
import XiangqiCore

enum ModelRecognizedPositionPolicy {
    static func validatedPosition(fen: String, sideToMove: Side) throws -> Position {
        let trimmed = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
        let normalizedFEN: String
        if fields.count >= 2, fields.count <= 6 {
            normalizedFEN = trimmed
        } else if let placement = fields.first(where: {
            $0.split(separator: "/", omittingEmptySubsequences: false).count == 10
        }) {
            normalizedFEN = "\(placement) \(sideToMove == .red ? "w" : "b") - - 0 1"
        } else {
            normalizedFEN = trimmed
        }
        let decoded = try Position(fen: normalizedFEN)
        let board = decoded.board
        guard board.pieceCount() <= 32,
              board.generalSquare(for: .red) != nil,
              board.generalSquare(for: .black) != nil else {
            throw XiangqiError.invalidFEN("模型局面必须包含双方将帅且不超过32枚")
        }

        let limits: [PieceKind: Int] = [
            .general: 1, .advisor: 2, .elephant: 2, .horse: 2,
            .chariot: 2, .cannon: 2, .soldier: 5
        ]
        for side in Side.allCases {
            for (kind, limit) in limits {
                let count = board.placements.filter {
                    $0.piece.side == side && $0.piece.kind == kind
                }.count
                guard count <= limit else {
                    throw XiangqiError.invalidFEN("模型识别的\(side)\(kind)数量超过初始上限")
                }
            }
        }

        return Position(board: board, sideToMove: sideToMove)
    }
}
