import Testing
@testable import XiangqiCore

struct GridGameCoreTests {
    @Test func gomokuDetectsFiveAndEngineTakesImmediateWin() throws {
        var position = GomokuPosition(size: 15)
        for point in [
            GridCoordinate(column: 3, row: 7), GridCoordinate(column: 3, row: 0),
            GridCoordinate(column: 4, row: 7), GridCoordinate(column: 4, row: 0),
            GridCoordinate(column: 5, row: 7), GridCoordinate(column: 5, row: 0),
            GridCoordinate(column: 6, row: 7), GridCoordinate(column: 6, row: 0)
        ] {
            position = try position.applying(point)
        }
        #expect(GomokuHeuristicEngine.bestMove(in: position) == GridCoordinate(column: 2, row: 7)
            || GomokuHeuristicEngine.bestMove(in: position) == GridCoordinate(column: 7, row: 7))
        let finished = try position.applying(try #require(GomokuHeuristicEngine.bestMove(in: position)))
        #expect(finished.status == .win(.black))
    }

    @Test func gomokuRejectsOccupiedAndOutOfBoard() throws {
        let position = try GomokuPosition().applying(GridCoordinate(column: 7, row: 7))
        #expect(throws: GomokuError.occupied) {
            _ = try position.applying(GridCoordinate(column: 7, row: 7))
        }
        #expect(throws: GomokuError.outOfBounds) {
            _ = try position.applying(GridCoordinate(column: -1, row: 7))
        }
    }

    @Test func goCapturesSurroundedStone() throws {
        var position = GoPosition(size: 9)
        // Build a legal sequence with one white stone ultimately surrounded.
        position = try position.applying(.play(GridCoordinate(column: 1, row: 0))) // B
        position = try position.applying(.play(GridCoordinate(column: 1, row: 1))) // W
        position = try position.applying(.play(GridCoordinate(column: 0, row: 1))) // B
        position = try position.applying(.play(GridCoordinate(column: 8, row: 8))) // W filler
        position = try position.applying(.play(GridCoordinate(column: 2, row: 1))) // B
        position = try position.applying(.play(GridCoordinate(column: 8, row: 7))) // W filler
        position = try position.applying(.play(GridCoordinate(column: 1, row: 2))) // B captures
        #expect(position.stones[GridCoordinate(column: 1, row: 1)] == nil)
    }

    @Test func goPassesFinishAndAreaScoreIsReported() throws {
        var position = GoPosition(size: 9)
        position = try position.applying(.play(GridCoordinate(column: 4, row: 4)))
        position = try position.applying(.pass)
        position = try position.applying(.pass)
        guard case let .finished(blackScore, whiteScore) = position.status else {
            Issue.record("Expected finished game after two passes")
            return
        }
        #expect(blackScore > whiteScore)
    }
}
