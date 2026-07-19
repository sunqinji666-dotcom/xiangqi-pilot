import Testing
@testable import XiangqiCore

@Suite struct AlphaBetaEngineTests {
    @Test func engineReturnsRankedLegalCandidates() async throws {
        let engine = AlphaBetaEngine()
        let analysis = try await engine.analyze(
            position: .standard,
            level: .instant,
            maxCandidates: 4
        )

        #expect(analysis.side == .red)
        #expect(analysis.positionKey == Position.standard.key)
        #expect(!analysis.candidates.isEmpty)
        #expect(analysis.candidates.count <= 4)
        #expect(analysis.terminalStatus == nil)
        #expect(analysis.candidates.allSatisfy {
            Position.standard.board.isLegal($0.move, for: .red)
        })
        #expect(analysis.candidates.allSatisfy {
            $0.principalVariation.first == $0.move
        })
        #expect(
            analysis.candidates.map(\.score)
                == analysis.candidates.map(\.score).sorted(by: >)
        )
        #expect(analysis.bestMove == analysis.candidates.first?.move)
    }

    @Test func engineFindsImmediateGeneralCapture() async throws {
        let position = try Position(
            fen: "4k4/4R4/9/9/9/9/9/9/9/3K5 w - - 0 1"
        )
        let analysis = try await AlphaBetaEngine().analyze(
            position: position,
            level: .casual,
            maxCandidates: 3
        )

        #expect(analysis.bestMove == move("e8e9"))
        #expect(analysis.candidates.first?.score == AlphaBetaEngine.mateScore - 1)
    }

    @Test func terminalPositionReturnsNoCandidate() async throws {
        let position = try Position(
            fen: "4k4/4R4/3R1R3/9/9/9/9/9/9/4K4 b - - 0 1"
        )
        let analysis = try await AlphaBetaEngine().analyze(
            position: position,
            level: .instant
        )

        #expect(analysis.candidates.isEmpty)
        #expect(analysis.searchedDepth == 0)
        #expect(analysis.terminalStatus == .checkmate(loser: .black, winner: .red))
    }

    @Test func thinkingLevelsHaveIncreasingBudgets() {
        let levels = ThinkingLevel.allCases.map(\.limits)
        #expect(levels.map(\.maxDepth) == levels.map(\.maxDepth).sorted())
        #expect(
            levels.map(\.timeLimitMilliseconds)
                == levels.map(\.timeLimitMilliseconds).sorted()
        )
        #expect(levels.map(\.maxNodes) == levels.map(\.maxNodes).sorted())
    }

    @Test func preCancelledSearchThrowsCancellationError() async {
        let token = SearchCancellationToken()
        token.cancel()

        do {
            _ = try await AlphaBetaEngine().analyze(
                position: .standard,
                level: .strong,
                cancellationToken: token
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func synchronousCustomLimitsRespectCandidateCount() throws {
        let analysis = try AlphaBetaEngine().analyzeSynchronously(
            position: .standard,
            limits: SearchLimits(
                maxDepth: 2,
                timeLimitMilliseconds: 150,
                maxNodes: 10_000
            ),
            maxCandidates: 2
        )

        #expect(analysis.candidates.count == 2)
        #expect(analysis.searchedDepth <= 2)
        #expect(analysis.nodes > 0)
        #expect(analysis.elapsedMilliseconds >= 0)
    }
}
