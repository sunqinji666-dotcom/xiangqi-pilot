import Testing
@testable import XiangqiPilotApp

@Suite struct UCCIEngineClientTests {
    @Test func primaryPikaFishInfoCapturesFullTelemetry() {
        var parser = EngineInfoAccumulator()
        parser.consume(line: "info depth 24 seldepth 37 multipv 1 score cp 83 nodes 991234 nps 831000 time 1193 pv b2b7 h7h2 i0i1")

        #expect(parser.depth == 24)
        #expect(parser.selectiveDepth == 37)
        #expect(parser.scoreCentipawns == 83)
        #expect(parser.mateInMoves == nil)
        #expect(parser.nodes == 991_234)
        #expect(parser.nodesPerSecond == 831_000)
        #expect(parser.engineTimeMilliseconds == 1_193)
        #expect(parser.principalVariation == ["b2b7", "h7h2", "i0i1"])
    }

    @Test func mateScoreNeverPretendsToBeCentipawns() {
        var parser = EngineInfoAccumulator()
        parser.consume(line: "info depth 18 score cp 35 pv b2b7 h7h2")
        parser.consume(line: "info depth 19 score mate -3 pv b2b7 h7h2")

        #expect(parser.depth == 19)
        #expect(parser.scoreCentipawns == nil)
        #expect(parser.mateInMoves == -3)
    }

    @Test func secondaryVariationCannotOverwritePrimaryTelemetry() {
        var parser = EngineInfoAccumulator()
        parser.consume(line: "info depth 20 multipv 1 score cp 12 nodes 100 nps 1000 time 100 pv b2b7 h7h2")
        parser.consume(line: "info depth 20 multipv 2 score cp 91 nodes 900 nps 9_000 time 900 pv a0a1 b0b1")

        #expect(parser.scoreCentipawns == 12)
        #expect(parser.nodes == 100)
        #expect(parser.nodesPerSecond == 1_000)
        #expect(parser.engineTimeMilliseconds == 100)
        #expect(parser.principalVariation == ["b2b7", "h7h2"])
    }

    @Test func malformedInfoDoesNotEraseEarlierGoodData() {
        var parser = EngineInfoAccumulator()
        parser.consume(line: "info depth 16 score cp -42 nodes 420 pv b2b7 h7h2")
        parser.consume(line: "info depth nope score mate ??? nodes invalid pv")

        #expect(parser.depth == 16)
        #expect(parser.scoreCentipawns == -42)
        #expect(parser.mateInMoves == nil)
        #expect(parser.nodes == 420)
        #expect(parser.principalVariation == ["b2b7", "h7h2"])
    }
}
