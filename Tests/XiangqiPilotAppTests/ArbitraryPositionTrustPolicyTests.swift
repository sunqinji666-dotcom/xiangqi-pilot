import Testing
@testable import XiangqiPilotApp

@Suite struct ArbitraryPositionTrustPolicyTests {
    @Test func legacyRecognitionNeverEstablishesAnArbitraryMidgameBaseline() {
        #expect(!ArbitraryPositionTrustPolicy.mayEstablishBaseline(
            backend: .legacyVisionFallback,
            snapshot: completeLookingSnapshot()
        ))
    }

    @Test func singleLocalModelStillNeedsIndependentEvidenceBeforeItEstablishesABaseline() {
        #expect(!ArbitraryPositionTrustPolicy.mayEstablishBaseline(
            backend: .localDetector(modelName: "xiangqi-cell-v1"),
            snapshot: completeLookingSnapshot()
        ))

        #expect(ArbitraryPositionTrustPolicy.mayEstablishBaseline(
            backend: .localDetector(modelName: "xiangqi-cell-v1"),
            snapshot: completeLookingSnapshot(),
            hasIndependentEvidence: true
        ))

        let incomplete = XiangqiRecognitionSnapshot(
            frameSequence: 1,
            pieces: [],
            occupiedCells: [],
            confidence: 1,
            warnings: []
        )
        #expect(!ArbitraryPositionTrustPolicy.mayEstablishBaseline(
            backend: .localDetector(modelName: "xiangqi-cell-v1"),
            snapshot: incomplete,
            hasIndependentEvidence: true
        ))
    }

    private func completeLookingSnapshot() -> XiangqiRecognitionSnapshot {
        XiangqiRecognitionSnapshot(
            frameSequence: 1,
            pieces: [
                RecognizedPiece(file: 4, rank: 9, side: .red, kind: .general, confidence: 0.99, glyph: "帥"),
                RecognizedPiece(file: 4, rank: 0, side: .black, kind: .general, confidence: 0.99, glyph: "將")
            ],
            confidence: 0.99,
            warnings: []
        )
    }
}
