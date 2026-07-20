import Foundation
import XiangqiCore

/// Rule gate for non-symbol grid boards.  A recognizer may report coloured
/// stones, but the cockpit only accepts a position or transition that can be
/// produced by the corresponding rules core.
enum GridGameTransitionPolicy {
    static func initialGomokuPosition(
        size: Int,
        stones: [GridCoordinate: GridStone]
    ) -> GomokuPosition? {
        let black = stones.values.filter { $0 == .black }.count
        let white = stones.values.filter { $0 == .white }.count
        // Black moves first; an arbitrary screenshot must satisfy this basic
        // invariant before it becomes a trusted digital position.
        guard black == white || black == white + 1 else { return nil }
        return GomokuPosition(
            size: size,
            stones: stones,
            sideToMove: black == white ? .black : .white
        )
    }

    static func nextGomokuMove(
        from position: GomokuPosition,
        observed stones: [GridCoordinate: GridStone]
    ) -> GridCoordinate? {
        position.legalMoves.first { point in
            guard let after = try? position.applying(point) else { return false }
            return after.stones == stones
        }
    }

    static func initialGoPosition(
        size: Int,
        stones: [GridCoordinate: GridStone]
    ) -> GoPosition? {
        let black = stones.values.filter { $0 == .black }.count
        let white = stones.values.filter { $0 == .white }.count
        // Go may begin with handicap stones, but White can never lead Black.
        guard black >= white, black - white <= 9 else { return nil }
        return GoPosition(
            size: size,
            stones: stones,
            sideToMove: black == white ? .black : .white
        )
    }

    static func nextGoMove(
        from position: GoPosition,
        observed stones: [GridCoordinate: GridStone]
    ) -> GoMove? {
        position.legalMoves.first { move in
            guard let after = try? position.applying(move) else { return false }
            return after.stones == stones
        }
    }

    /// Some clients paint the last-move indicator over the centre of a stone.
    /// That can transiently change only the recognised colour while every
    /// occupied intersection remains identical. It is a rendering ambiguity,
    /// not evidence of a move, so callers must wait for a later stable frame
    /// instead of treating it as an illegal position transition.
    static func hasMatchingOccupancy(
        trusted: [GridCoordinate: GridStone],
        observed: [GridCoordinate: GridStone]
    ) -> Bool {
        trusted.keys == observed.keys
    }

    /// Returns true when the recognizer's disagreement is isolated to one
    /// already-proven intersection. This covers a last-move badge temporarily
    /// hiding the white stone beneath it, while still rejecting any change to
    /// every other occupied intersection.
    static func differsOnlyAt(
        _ coordinate: GridCoordinate,
        trusted: [GridCoordinate: GridStone],
        observed: [GridCoordinate: GridStone]
    ) -> Bool {
        trusted.filter { $0.key != coordinate } == observed.filter { $0.key != coordinate }
    }
}
