import Foundation
import XiangqiCore

enum PositionRecoverySafetyPolicy {
    struct Evidence {
        let position: Position
        let confidence: Double
    }

    /// A model's self-reported confidence is never sufficient by itself.
    /// Automatic replacement requires independent agreement on every square.
    static func canAutoApply(
        local: Evidence?,
        models: [Evidence],
        minimumConfidence: Double = 0.88
    ) -> Bool {
        let qualifiedModels = models.filter { $0.confidence >= minimumConfidence }
        if let local,
           local.confidence >= minimumConfidence,
           qualifiedModels.contains(where: { $0.position.board == local.position.board }) {
            return true
        }
        for index in qualifiedModels.indices {
            for otherIndex in qualifiedModels.indices where otherIndex > index {
                if qualifiedModels[index].position.board == qualifiedModels[otherIndex].position.board {
                    return true
                }
            }
        }
        return false
    }
}
