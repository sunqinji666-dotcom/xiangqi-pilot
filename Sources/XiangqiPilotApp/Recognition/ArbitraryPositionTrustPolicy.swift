import Foundation

/// A complete-looking OCR result is not the same thing as a trustworthy
/// arbitrary Xiangqi position.  The legacy OCR/template route is useful for
/// drafts and recovery hints, but it has no calibrated 14-class model and may
/// confidently confuse similar glyphs.  Standard-opening recovery and an
/// authoritative client move log are handled by their own rules; this policy
/// only governs a newly established midgame baseline from one visual frame.
enum ArbitraryPositionTrustPolicy {
    static func mayEstablishBaseline(
        backend: XiangqiPieceRecognizerBackend,
        snapshot: XiangqiRecognitionSnapshot,
        hasIndependentEvidence: Bool = false
    ) -> Bool {
        backend.canAuthoritativelyClassifyArbitraryPosition
            && !snapshot.requiresHumanReview
            && hasIndependentEvidence
    }
}
