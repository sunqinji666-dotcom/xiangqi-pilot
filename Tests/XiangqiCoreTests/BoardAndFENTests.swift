import Testing
@testable import XiangqiCore

@Suite struct BoardAndFENTests {
    private let initialFEN = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

    @Test func standardPositionHasAllPiecesAndCanonicalFEN() throws {
        let position = Position.standard

        #expect(position.board.pieceCount() == 32)
        #expect(position.board.pieceCount(for: .red) == 16)
        #expect(position.board.pieceCount(for: .black) == 16)
        #expect(position.board[square(4, 9)] == piece(.red, .general))
        #expect(position.board[square(1, 2)] == piece(.black, .cannon))
        #expect(position.fen == initialFEN)
        #expect(try Position(fen: initialFEN) == position)
    }

    @Test func fenSupportsArbitraryPositionCountersAndAliases() throws {
        let position = try Position(
            fen: "4g4/9/9/9/9/4P4/9/9/9/4G4 b - - 17 42"
        )

        #expect(position.sideToMove == .black)
        #expect(position.halfmoveClock == 17)
        #expect(position.fullmoveNumber == 42)
        #expect(position.board[square(4, 0)] == piece(.black, .general))
        #expect(position.board[square(4, 9)] == piece(.red, .general))
        #expect(position.fen == "4k4/9/9/9/9/4P4/9/9/9/4K4 b - - 17 42")
    }

    @Test func fenCanRepresentTerminalGeneralCapture() throws {
        let position = try Position(fen: "9/9/9/9/9/9/9/9/9/4K4 b - - 0 12")
        #expect(position.status == .generalCaptured(loser: .black, winner: .red))
        #expect(position.fen == "9/9/9/9/9/9/9/9/9/4K4 b - - 0 12")
    }

    @Test func invalidFENIsRejected() {
        let invalidFENs = [
            "9/9 w - - 0 1",
            "10/9/9/9/9/9/9/9/9/9 w - - 0 1",
            "8x/9/9/9/9/9/9/9/9/9 w - - 0 1",
            "4k4/9/9/9/9/9/9/9/9/3KK4 w - - 0 1",
            "9/9/9/9/9/9/9/9/9/9 q - - 0 1",
            "9/9/9/9/9/9/9/9/9/9 w K - 0 1",
            "9/9/9/9/9/9/9/9/9/9 w - - -1 1"
        ]

        for fen in invalidFENs {
            #expect(throws: XiangqiError.self, "\(fen)") {
                try Position(fen: fen)
            }
        }
    }

    @Test func squareAndMoveUCCIRoundTrip() {
        #expect(Square(ucci: "a0") == square(0, 9))
        #expect(Square(ucci: "i9") == square(8, 0))
        #expect(Square(ucci: "j0") == nil)
        #expect(Square(ucci: "aA") == nil)

        let parsed = Move(ucci: "b0c2")
        #expect(parsed?.from == square(1, 9))
        #expect(parsed?.to == square(2, 7))
        #expect(parsed?.ucci == "b0c2")
        #expect(Move(ucci: "a0a10") == nil)
    }

    @Test func duplicatePlacementIsRejected() {
        let location = square(4, 9)
        do {
            _ = try Board(placements: [
                Placement(piece(.red, .general), at: location),
                Placement(piece(.red, .advisor), at: location)
            ])
            Issue.record("Expected duplicate placement error")
        } catch {
            #expect(error as? XiangqiError == .duplicatePlacement(location))
        }
    }
}
