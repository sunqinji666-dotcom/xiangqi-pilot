import Foundation
import XiangqiCore

enum XiangqiPieceInventoryError: LocalizedError, Equatable {
    case implausibleInventory(String)
    case unexplainedIncrease
    case invalidCaptureDelta
    case movedPieceChangedIdentity

    var errorDescription: String? {
        switch self {
        case .implausibleInventory(let detail):
            return "棋子库存不可能：\(detail)"
        case .unexplainedIncrease:
            return "棋子数量无合法依据增加"
        case .invalidCaptureDelta:
            return "吃子后的棋子数量变化不符合唯一合法着法"
        case .movedPieceChangedIdentity:
            return "移动棋子的颜色或类型发生了不可能变化"
        }
    }
}

enum XiangqiPieceInventoryPolicy {
    private static let maxima: [PieceKind: Int] = [
        .general: 1,
        .advisor: 2,
        .elephant: 2,
        .horse: 2,
        .chariot: 2,
        .cannon: 2,
        .soldier: 5
    ]

    /// Used by the correction UI to keep its draft physically plausible as
    /// the user edits, rather than discovering an excess piece only on save.
    static func maximum(for kind: PieceKind) -> Int {
        maxima[kind] ?? 0
    }

    static func validate(_ board: Board) throws {
        for side in Side.allCases {
            for kind in PieceKind.allCases {
                let count = board.placements.filter {
                    $0.piece.side == side && $0.piece.kind == kind
                }.count
                let maximum = maxima[kind] ?? 0
                guard count <= maximum else {
                    throw XiangqiPieceInventoryError.implausibleInventory(
                        "\(side == .red ? "红" : "黑")\(kind) \(count)>上限\(maximum)"
                    )
                }
            }
        }
    }

    static func validateTransition(
        before: Position,
        move: Move,
        after: Position
    ) throws {
        try validate(before.board)
        try validate(after.board)
        guard let movingPiece = before.board[move.from],
              after.board[move.from] == nil,
              after.board[move.to] == movingPiece else {
            throw XiangqiPieceInventoryError.movedPieceChangedIdentity
        }

        let captured = before.board[move.to]
        let expectedTotal = before.board.pieceCount() - (captured == nil ? 0 : 1)
        guard after.board.pieceCount() == expectedTotal else {
            throw captured == nil
                ? XiangqiPieceInventoryError.unexplainedIncrease
                : XiangqiPieceInventoryError.invalidCaptureDelta
        }

        for side in Side.allCases {
            for kind in PieceKind.allCases {
                let beforeCount = count(side: side, kind: kind, board: before.board)
                let afterCount = count(side: side, kind: kind, board: after.board)
                let expectedDecrease = captured?.side == side && captured?.kind == kind ? 1 : 0
                guard afterCount == beforeCount - expectedDecrease else {
                    throw afterCount > beforeCount
                        ? XiangqiPieceInventoryError.unexplainedIncrease
                        : XiangqiPieceInventoryError.invalidCaptureDelta
                }
            }
        }
    }

    private static func count(side: Side, kind: PieceKind, board: Board) -> Int {
        board.placements.filter { $0.piece.side == side && $0.piece.kind == kind }.count
    }
}
