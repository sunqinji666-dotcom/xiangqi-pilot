import CoreGraphics
import Foundation

enum BoardChangeObservation: Sendable {
    case primed(BoardFrameSignature)
    case unchanged(BoardFrameSignature)
    case candidate(change: BoardVisualChange, stableFrames: Int)
    case stable(change: BoardVisualChange, signature: BoardFrameSignature)
}

/// Hot path for a connected board.  It samples only the calibrated 9×10
/// intersections through `BoardFrameDifferencer`; it never invokes OCR or a
/// cloud model.  A changed pattern must remain materially identical for the
/// configured number of board frames before the rules synchronizer sees it.
/// Runtime owns this on its main actor, so a lightweight class avoids one
/// asynchronous hop for every 15–20fps capture frame.
final class BoardChangeDetector {
    private let differencer: BoardFrameDifferencer
    private let minimumScore: Double
    private let requiredStableFrames: Int
    private var baseline: BoardFrameSignature?
    private var candidateSignature: BoardFrameSignature?
    private var candidateChange: BoardVisualChange?
    private var candidateFrames = 0

    init(
        differencer: BoardFrameDifferencer = BoardFrameDifferencer(),
        minimumScore: Double = 0.07,
        requiredStableFrames: Int = 2
    ) {
        self.differencer = differencer
        self.minimumScore = minimumScore
        self.requiredStableFrames = max(2, requiredStableFrames)
    }

    func ingest(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry
    ) -> BoardChangeObservation {
        ingest(signature: differencer.signature(
            image: image,
            frameSequence: frameSequence,
            geometry: geometry
        ))
    }

    func ingest(signature: BoardFrameSignature) -> BoardChangeObservation {
        guard let baseline else {
            self.baseline = signature
            return .primed(signature)
        }
        let change = differencer.changes(from: baseline, to: signature, minimumScore: minimumScore)
        guard !change.cells.isEmpty else {
            clearCandidate()
            return .unchanged(signature)
        }

        let sameChangedCells = candidateChange.map { previous in
            Set(previous.cells.map(\.coordinate)) == Set(change.cells.map(\.coordinate))
        } ?? false
        let boardStoppedChanging: Bool
        if let candidateSignature {
            boardStoppedChanging = differencer.changes(
                from: candidateSignature,
                to: signature,
                minimumScore: minimumScore * 0.5
            ).cells.isEmpty
        } else {
            boardStoppedChanging = false
        }

        if sameChangedCells && boardStoppedChanging {
            candidateFrames += 1
        } else {
            candidateChange = change
            candidateSignature = signature
            candidateFrames = 1
        }
        if candidateFrames >= requiredStableFrames {
            return .stable(change: change, signature: signature)
        }
        return .candidate(change: change, stableFrames: candidateFrames)
    }

    /// Call only after the rules layer accepts the corresponding move. An
    /// unexplained visual change must retain the old baseline for recovery.
    func accept(signature: BoardFrameSignature) {
        baseline = signature
        clearCandidate()
    }

    func reset() {
        baseline = nil
        clearCandidate()
    }

    private func clearCandidate() {
        candidateSignature = nil
        candidateChange = nil
        candidateFrames = 0
    }
}
