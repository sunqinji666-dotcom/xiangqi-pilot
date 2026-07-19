public struct Board: Equatable, Sendable {
    public static let width = 9
    public static let height = 10

    private var storage: [Piece?]

    public init() {
        storage = Array(repeating: nil, count: Self.width * Self.height)
    }

    public init(placements: [Placement]) throws {
        self.init()
        for placement in placements {
            guard self[placement.square] == nil else {
                throw XiangqiError.duplicatePlacement(placement.square)
            }
            self[placement.square] = placement.piece
        }
    }

    public subscript(square: Square) -> Piece? {
        get { storage[index(for: square)] }
        set { storage[index(for: square)] = newValue }
    }

    public static var standard: Board {
        var board = Board()
        let backRank: [PieceKind] = [
            .chariot, .horse, .elephant, .advisor, .general,
            .advisor, .elephant, .horse, .chariot
        ]

        for (file, kind) in backRank.enumerated() {
            board[Square(file: file, rank: 0)] = Piece(side: .black, kind: kind)
            board[Square(file: file, rank: 9)] = Piece(side: .red, kind: kind)
        }

        board[Square(file: 1, rank: 2)] = Piece(side: .black, kind: .cannon)
        board[Square(file: 7, rank: 2)] = Piece(side: .black, kind: .cannon)
        board[Square(file: 1, rank: 7)] = Piece(side: .red, kind: .cannon)
        board[Square(file: 7, rank: 7)] = Piece(side: .red, kind: .cannon)

        for file in stride(from: 0, through: 8, by: 2) {
            board[Square(file: file, rank: 3)] = Piece(side: .black, kind: .soldier)
            board[Square(file: file, rank: 6)] = Piece(side: .red, kind: .soldier)
        }
        return board
    }

    public var placements: [Placement] {
        var result: [Placement] = []
        result.reserveCapacity(32)
        for rank in 0..<Self.height {
            for file in 0..<Self.width {
                let square = Square(file: file, rank: rank)
                if let piece = self[square] {
                    result.append(Placement(piece, at: square))
                }
            }
        }
        return result
    }

    public func pieceCount(for side: Side? = nil) -> Int {
        placements.reduce(into: 0) { count, placement in
            if side == nil || placement.piece.side == side {
                count += 1
            }
        }
    }

    public func generalSquare(for side: Side) -> Square? {
        placements.first {
            $0.piece.side == side && $0.piece.kind == .general
        }?.square
    }

    public func generalsFaceEachOther() -> Bool {
        guard let red = generalSquare(for: .red),
              let black = generalSquare(for: .black),
              red.file == black.file else {
            return false
        }
        let lower = min(red.rank, black.rank) + 1
        let upper = max(red.rank, black.rank)
        guard lower < upper else { return true }
        for rank in lower..<upper where self[Square(file: red.file, rank: rank)] != nil {
            return false
        }
        return true
    }

    public func pseudoLegalMoves(for side: Side) -> [Move] {
        var moves: [Move] = []
        for placement in placements where placement.piece.side == side {
            appendPseudoLegalMoves(
                for: placement.piece,
                from: placement.square,
                to: &moves
            )
        }
        return moves
    }

    public func legalMoves(for side: Side) -> [Move] {
        guard generalSquare(for: side) != nil else { return [] }
        return pseudoLegalMoves(for: side).filter { move in
            let next = applyingUnchecked(move)
            return !next.isInCheck(side)
        }
    }

    public func isPseudoLegal(_ move: Move, for side: Side) -> Bool {
        guard self[move.from]?.side == side else { return false }
        return pseudoLegalMoves(for: side).contains(move)
    }

    public func isLegal(_ move: Move, for side: Side) -> Bool {
        guard generalSquare(for: side) != nil,
              isPseudoLegal(move, for: side) else {
            return false
        }
        return !applyingUnchecked(move).isInCheck(side)
    }

    public func isInCheck(_ side: Side) -> Bool {
        guard let general = generalSquare(for: side) else { return true }
        return pseudoLegalMoves(for: side.opponent).contains { $0.to == general }
    }

    public func applying(_ move: Move, for side: Side) throws -> Board {
        guard let piece = self[move.from] else {
            throw XiangqiError.noPieceAtSource(move.from)
        }
        guard piece.side == side else {
            throw XiangqiError.wrongSide(expected: side, actual: piece.side)
        }
        guard isLegal(move, for: side) else {
            throw XiangqiError.illegalMove(move)
        }
        return applyingUnchecked(move)
    }

    internal func applyingUnchecked(_ move: Move) -> Board {
        var copy = self
        copy[move.to] = copy[move.from]
        copy[move.from] = nil
        return copy
    }

    private func index(for square: Square) -> Int {
        square.rank * Self.width + square.file
    }

    private func appendPseudoLegalMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        switch piece.kind {
        case .general:
            appendGeneralMoves(for: piece, from: origin, to: &moves)
        case .advisor:
            appendAdvisorMoves(for: piece, from: origin, to: &moves)
        case .elephant:
            appendElephantMoves(for: piece, from: origin, to: &moves)
        case .horse:
            appendHorseMoves(for: piece, from: origin, to: &moves)
        case .chariot:
            appendChariotMoves(for: piece, from: origin, to: &moves)
        case .cannon:
            appendCannonMoves(for: piece, from: origin, to: &moves)
        case .soldier:
            appendSoldierMoves(for: piece, from: origin, to: &moves)
        }
    }

    private func appendGeneralMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        for (fileDelta, rankDelta) in Self.orthogonalDirections {
            let file = origin.file + fileDelta
            let rank = origin.rank + rankDelta
            guard Self.isInsidePalace(file: file, rank: rank, for: piece.side) else { continue }
            appendIfEmptyOrEnemy(from: origin, file: file, rank: rank, side: piece.side, to: &moves)
        }

        // The flying-general capture is also what makes an open general file a check.
        for rankDelta in [-1, 1] {
            var rank = origin.rank + rankDelta
            while Square.isValid(file: origin.file, rank: rank) {
                let target = Square(file: origin.file, rank: rank)
                if let occupant = self[target] {
                    if occupant.side != piece.side && occupant.kind == .general {
                        moves.append(Move(from: origin, to: target))
                    }
                    break
                }
                rank += rankDelta
            }
        }
    }

    private func appendAdvisorMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        for (fileDelta, rankDelta) in Self.diagonalDirections {
            let file = origin.file + fileDelta
            let rank = origin.rank + rankDelta
            guard Self.isInsidePalace(file: file, rank: rank, for: piece.side) else { continue }
            appendIfEmptyOrEnemy(from: origin, file: file, rank: rank, side: piece.side, to: &moves)
        }
    }

    private func appendElephantMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        for (fileDelta, rankDelta) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] {
            let file = origin.file + fileDelta
            let rank = origin.rank + rankDelta
            guard Square.isValid(file: file, rank: rank),
                  Self.isOnOwnSideOfRiver(rank: rank, for: piece.side) else {
                continue
            }
            let eye = Square(
                file: origin.file + fileDelta / 2,
                rank: origin.rank + rankDelta / 2
            )
            guard self[eye] == nil else { continue }
            appendIfEmptyOrEnemy(from: origin, file: file, rank: rank, side: piece.side, to: &moves)
        }
    }

    private func appendHorseMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        let jumps = [
            (-2, -1), (-2, 1), (2, -1), (2, 1),
            (-1, -2), (1, -2), (-1, 2), (1, 2)
        ]
        for (fileDelta, rankDelta) in jumps {
            let file = origin.file + fileDelta
            let rank = origin.rank + rankDelta
            guard Square.isValid(file: file, rank: rank) else { continue }
            let leg: Square
            if abs(fileDelta) == 2 {
                leg = Square(file: origin.file + fileDelta / 2, rank: origin.rank)
            } else {
                leg = Square(file: origin.file, rank: origin.rank + rankDelta / 2)
            }
            guard self[leg] == nil else { continue }
            appendIfEmptyOrEnemy(from: origin, file: file, rank: rank, side: piece.side, to: &moves)
        }
    }

    private func appendChariotMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        for direction in Self.orthogonalDirections {
            var file = origin.file + direction.0
            var rank = origin.rank + direction.1
            while Square.isValid(file: file, rank: rank) {
                let target = Square(file: file, rank: rank)
                if let occupant = self[target] {
                    if occupant.side != piece.side {
                        moves.append(Move(from: origin, to: target))
                    }
                    break
                }
                moves.append(Move(from: origin, to: target))
                file += direction.0
                rank += direction.1
            }
        }
    }

    private func appendCannonMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        for direction in Self.orthogonalDirections {
            var file = origin.file + direction.0
            var rank = origin.rank + direction.1
            var foundScreen = false
            while Square.isValid(file: file, rank: rank) {
                let target = Square(file: file, rank: rank)
                if let occupant = self[target] {
                    if !foundScreen {
                        foundScreen = true
                    } else {
                        if occupant.side != piece.side {
                            moves.append(Move(from: origin, to: target))
                        }
                        break
                    }
                } else if !foundScreen {
                    moves.append(Move(from: origin, to: target))
                }
                file += direction.0
                rank += direction.1
            }
        }
    }

    private func appendSoldierMoves(
        for piece: Piece,
        from origin: Square,
        to moves: inout [Move]
    ) {
        let forwardRank = origin.rank + piece.side.forwardRankDelta
        appendIfEmptyOrEnemy(
            from: origin,
            file: origin.file,
            rank: forwardRank,
            side: piece.side,
            to: &moves
        )

        if Self.hasCrossedRiver(origin.rank, side: piece.side) {
            appendIfEmptyOrEnemy(
                from: origin,
                file: origin.file - 1,
                rank: origin.rank,
                side: piece.side,
                to: &moves
            )
            appendIfEmptyOrEnemy(
                from: origin,
                file: origin.file + 1,
                rank: origin.rank,
                side: piece.side,
                to: &moves
            )
        }
    }

    private func appendIfEmptyOrEnemy(
        from origin: Square,
        file: Int,
        rank: Int,
        side: Side,
        to moves: inout [Move]
    ) {
        guard Square.isValid(file: file, rank: rank) else { return }
        let target = Square(file: file, rank: rank)
        if self[target]?.side != side {
            moves.append(Move(from: origin, to: target))
        }
    }

    private static let orthogonalDirections = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    private static let diagonalDirections = [(-1, -1), (1, -1), (-1, 1), (1, 1)]

    private static func isInsidePalace(file: Int, rank: Int, for side: Side) -> Bool {
        guard (3...5).contains(file) else { return false }
        switch side {
        case .black: return (0...2).contains(rank)
        case .red: return (7...9).contains(rank)
        }
    }

    private static func isOnOwnSideOfRiver(rank: Int, for side: Side) -> Bool {
        side == .red ? rank >= 5 : rank <= 4
    }

    private static func hasCrossedRiver(_ rank: Int, side: Side) -> Bool {
        side == .red ? rank <= 4 : rank >= 5
    }
}
