import Testing
@testable import XiangqiCore

@Suite struct LegalityAndGameTests {
    @Test func movingFileBlockerCannotExposeFacingGenerals() {
        let position = board([
            (piece(.black, .general), square(4, 0)),
            (piece(.red, .chariot), square(4, 5)),
            (piece(.red, .general), square(4, 9))
        ])
        let exposesFile = Move(from: square(4, 5), to: square(3, 5))
        let staysOnFile = Move(from: square(4, 5), to: square(4, 4))

        #expect(position.isPseudoLegal(exposesFile, for: .red))
        #expect(!position.isLegal(exposesFile, for: .red))
        #expect(position.isLegal(staysOnFile, for: .red))
    }

    @Test func generalCannotMoveOntoAttackedFile() {
        let position = board([
            (piece(.black, .general), square(3, 0)),
            (piece(.black, .chariot), square(5, 0)),
            (piece(.red, .general), square(4, 9))
        ])
        let moveIntoCheck = Move(from: square(4, 9), to: square(5, 9))

        #expect(position.isPseudoLegal(moveIntoCheck, for: .red))
        #expect(!position.isLegal(moveIntoCheck, for: .red))
    }

    @Test func checkStatus() throws {
        let position = try Position(
            fen: "4k4/9/9/9/9/4R4/9/9/9/3K5 b - - 0 1"
        )

        #expect(position.isInCheck)
        #expect(position.status == .check(side: .black))
        #expect(!position.legalMoves.isEmpty)
    }

    @Test func checkmateEndgame() throws {
        let position = try Position(
            fen: "4k4/4R4/3R1R3/9/9/9/9/9/9/4K4 b - - 0 1"
        )

        #expect(position.isInCheck)
        #expect(position.legalMoves.isEmpty)
        #expect(position.status == .checkmate(loser: .black, winner: .red))
    }

    @Test func stalemateIsLossInXiangqi() throws {
        let position = try Position(
            fen: "4k4/R8/3R1R3/9/9/4P4/9/9/9/4K4 b - - 0 1"
        )

        #expect(!position.isInCheck)
        #expect(position.legalMoves.isEmpty)
        #expect(position.status == .stalemate(loser: .black, winner: .red))
    }

    @Test func positionApplicationUpdatesTurnCountersAndCaptureClock() throws {
        var position = Position.standard
        position = try position.applying(move("a0a1"))
        #expect(position.sideToMove == .black)
        #expect(position.halfmoveClock == 1)
        #expect(position.fullmoveNumber == 1)

        position = try position.applying(move("a9a8"))
        #expect(position.sideToMove == .red)
        #expect(position.halfmoveClock == 2)
        #expect(position.fullmoveNumber == 2)

        let capturePosition = try Position(
            // The d-file soldier prevents an already-illegal flying-general
            // position while the two chariots meet on the e-file.
            fen: "3k5/9/9/9/3pr4/4R4/9/9/9/3K5 w - - 9 20"
        )
        let afterCapture = try capturePosition.applying(
            Move(from: square(4, 5), to: square(4, 4))
        )
        #expect(afterCapture.halfmoveClock == 0)
        #expect(afterCapture.board[square(4, 5)] == nil)
        #expect(afterCapture.board[square(4, 4)] == piece(.red, .chariot))
    }

    @Test func wrongSideAndIllegalMoveErrors() {
        do {
            _ = try Position.standard.applying(move("a9a8"))
            Issue.record("Expected wrong-side error")
        } catch {
            #expect(error as? XiangqiError == .wrongSide(expected: .red, actual: .black))
        }
        do {
            _ = try Position.standard.applying(move("a0b1"))
            Issue.record("Expected illegal-move error")
        } catch {
            #expect(error as? XiangqiError == .illegalMove(move("a0b1")))
        }
    }

    @Test func historyUndoAndThreefoldPositionTracking() throws {
        var game = Game()
        let initial = game.position
        let cycle = ["b0c2", "b9c7", "c2b0", "c7b9"]

        for _ in 0..<2 {
            for notation in cycle {
                try game.play(move(notation))
            }
        }

        // Move counters advance during a repeated board position. Repetition
        // identity intentionally compares placement + side, not FEN clocks.
        #expect(game.position.key == initial.key)
        #expect(game.moveHistory.count == 8)
        #expect(game.currentRepetitionCount == 3)
        #expect(game.isThreefoldRepetition)
        #expect(game.status == .repetition(count: 3))

        let undone = game.undo()
        #expect(undone?.move == move("c7b9"))
        #expect(game.repetitionCount(for: initial.key) == 2)
        #expect(!game.isThreefoldRepetition)

        while game.canUndo { game.undo() }
        #expect(game.position == initial)
        #expect(game.currentRepetitionCount == 1)
        #expect(game.records.isEmpty)
        #expect(game.undo() == nil)
    }

    @Test func moveRecordContainsCaptureAndCheckMetadata() throws {
        let start = try Position(
            fen: "4k4/9/9/9/4p4/4R4/9/9/9/3K5 w - - 0 1"
        )
        var game = Game(position: start)
        let record = try game.play(Move(from: square(4, 5), to: square(4, 4)))

        #expect(record.movingPiece == piece(.red, .chariot))
        #expect(record.capturedPiece == piece(.black, .soldier))
        #expect(record.positionBefore == start)
        #expect(record.positionAfter == game.position)
        #expect(record.gaveCheck)
    }

    @Test func initialPositionGeneratesOnlyLegalMoves() {
        let board = Board.standard
        let moves = board.legalMoves(for: .red)

        #expect(!moves.isEmpty)
        #expect(moves.count == 44)
        #expect(moves.allSatisfy { board.isLegal($0, for: .red) })
    }
}
