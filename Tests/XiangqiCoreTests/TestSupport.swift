import XiangqiCore

func square(_ file: Int, _ rank: Int) -> Square {
    Square(file: file, rank: rank)
}

func piece(_ side: Side, _ kind: PieceKind) -> Piece {
    Piece(side: side, kind: kind)
}

func board(_ placements: [(Piece, Square)]) -> Board {
    try! Board(placements: placements.map { Placement($0.0, at: $0.1) })
}

func move(_ ucci: String) -> Move {
    guard let move = Move(ucci: ucci) else {
        fatalError("Invalid test move: \(ucci)")
    }
    return move
}
