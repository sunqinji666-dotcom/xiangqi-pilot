import Testing
import XiangqiCore
@testable import XiangqiPilotApp

struct GridGameTransitionPolicyTests {
    @Test func gomokuAcceptsOnlyARealSingleLegalTransition() throws {
        let before = try #require(GridGameTransitionPolicy.initialGomokuPosition(
            size: 15,
            stones: [GridCoordinate(column: 7, row: 7): .black]
        ))
        let move = GridCoordinate(column: 8, row: 7)
        let after = try before.applying(move)
        #expect(GridGameTransitionPolicy.nextGomokuMove(from: before, observed: after.stones) == move)
        var impossible = after.stones
        impossible[GridCoordinate(column: 9, row: 7)] = .black
        #expect(GridGameTransitionPolicy.nextGomokuMove(from: before, observed: impossible) == nil)
    }

    @Test func goRecognizesCaptureTransitionThroughRules() throws {
        var before = GoPosition(size: 9)
        before = try before.applying(.play(GridCoordinate(column: 1, row: 0)))
        before = try before.applying(.play(GridCoordinate(column: 1, row: 1)))
        before = try before.applying(.play(GridCoordinate(column: 0, row: 1)))
        before = try before.applying(.play(GridCoordinate(column: 8, row: 8)))
        before = try before.applying(.play(GridCoordinate(column: 2, row: 1)))
        before = try before.applying(.play(GridCoordinate(column: 8, row: 7)))
        let move = GoMove.play(GridCoordinate(column: 1, row: 2))
        let after = try before.applying(move)
        #expect(GridGameTransitionPolicy.nextGoMove(from: before, observed: after.stones) == move)
    }

    @Test func matchingOccupancyTreatsLastMoveColourOverlayAsRenderingNoise() {
        let point = GridCoordinate(column: 9, row: 9)
        let trusted = [point: GridStone.white]
        let overlaySample = [point: GridStone.black]

        #expect(GridGameTransitionPolicy.hasMatchingOccupancy(
            trusted: trusted,
            observed: overlaySample
        ))
        #expect(!GridGameTransitionPolicy.hasMatchingOccupancy(
            trusted: trusted,
            observed: [GridCoordinate(column: 10, row: 9): .white]
        ))
    }

    @Test func lastMoveAnchorToleratesOnlyItsOwnTemporaryDisappearance() {
        let anchor = GridCoordinate(column: 9, row: 9)
        let other = GridCoordinate(column: 10, row: 9)
        let trusted = [anchor: GridStone.white, other: GridStone.black]

        #expect(GridGameTransitionPolicy.differsOnlyAt(
            anchor,
            trusted: trusted,
            observed: [other: .black]
        ))
        #expect(!GridGameTransitionPolicy.differsOnlyAt(
            anchor,
            trusted: trusted,
            observed: [other: .white]
        ))
    }
}
