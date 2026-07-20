import Foundation
import XiangqiCore

final class GridGameRuntimeState {
    var calibration: GridBoardCalibration?
    var gomokuPosition: GomokuPosition?
    var goPosition: GoPosition?
    var controlledSide: GridStone = .black
    /// Explicit opt-in test mode for local board clients that do not provide
    /// their own AI reply. Normal operation remains one-side control.
    var controlsBothSides = false
    var bootstrapStage = 0
    var lastObservedStones: [GridCoordinate: GridStone] = [:]
    let clickExecutor = GridClickExecutor()

    func reset() {
        calibration = nil
        gomokuPosition = nil
        goPosition = nil
        controlledSide = .black
        controlsBothSides = false
        bootstrapStage = 0
        lastObservedStones = [:]
    }
}
