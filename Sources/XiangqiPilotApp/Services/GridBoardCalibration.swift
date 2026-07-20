import CoreGraphics
import Foundation
import XiangqiCore

/// Perspective-aware geometry for a square, intersection-based board such as
/// Gomoku or Go.  It deliberately does not share Xiangqi's 9×10 limits.
struct GridBoardCalibration: Hashable, Sendable {
    let corners: BoardCorners
    let imageSize: CGSize
    let windowFrame: CGRect
    let lineCount: Int
    let geometryHash: String

    init(corners: BoardCorners, imageSize: CGSize, windowFrame: CGRect, lineCount: Int) throws {
        guard (5...25).contains(lineCount) else { throw BoardCalibrationError.degenerateBoard }
        let xiangqi = try BoardCalibration(corners: corners, imageSize: imageSize, windowFrame: windowFrame)
        self.corners = corners
        self.imageSize = imageSize
        self.windowFrame = windowFrame
        self.lineCount = lineCount
        self.geometryHash = "grid-\(lineCount)-\(xiangqi.geometryHash)"
    }

    func imagePoint(for coordinate: GridCoordinate) throws -> CGPoint {
        guard (0..<lineCount).contains(coordinate.column), (0..<lineCount).contains(coordinate.row) else {
            throw BoardCalibrationError.gridPointOutOfRange(file: coordinate.column, rank: coordinate.row)
        }
        let u = CGFloat(coordinate.column) / CGFloat(lineCount - 1)
        let v = CGFloat(coordinate.row) / CGFloat(lineCount - 1)
        let top = interpolate(corners.topLeft, corners.topRight, fraction: u)
        let bottom = interpolate(corners.bottomLeft, corners.bottomRight, fraction: u)
        return interpolate(top, bottom, fraction: v)
    }

    func globalScreenPoint(for coordinate: GridCoordinate, in liveWindowFrame: CGRect) throws -> CGPoint {
        guard abs(liveWindowFrame.width - windowFrame.width) <= 0.5,
              abs(liveWindowFrame.height - windowFrame.height) <= 0.5 else {
            throw BoardCalibrationError.invalidWindowFrame
        }
        // Some mobile-board wrappers only accept a hit slightly inside the
        // painted outer line. Keep recognition on the true intersections, but
        // bias input by a tiny fraction towards the board centre at an outer
        // edge so a valid O/P-file move cannot land on the decorative frame.
        let point = try inputImagePoint(for: coordinate)
        return CGPoint(
            x: liveWindowFrame.minX + point.x * liveWindowFrame.width / imageSize.width,
            y: liveWindowFrame.minY + point.y * liveWindowFrame.height / imageSize.height
        )
    }

    private func inputImagePoint(for coordinate: GridCoordinate) throws -> CGPoint {
        guard (0..<lineCount).contains(coordinate.column), (0..<lineCount).contains(coordinate.row) else {
            throw BoardCalibrationError.gridPointOutOfRange(file: coordinate.column, rank: coordinate.row)
        }
        let spacing = localSpacing()
        let horizontalInset = min(0.075, 2.0 / max(1, spacing.width))
        let verticalInset = min(0.075, 2.0 / max(1, spacing.height))
        var u = CGFloat(coordinate.column) / CGFloat(lineCount - 1)
        var v = CGFloat(coordinate.row) / CGFloat(lineCount - 1)
        if coordinate.column == 0 { u += horizontalInset }
        if coordinate.column == lineCount - 1 { u -= horizontalInset }
        if coordinate.row == 0 { v += verticalInset }
        if coordinate.row == lineCount - 1 { v -= verticalInset }
        let top = interpolate(corners.topLeft, corners.topRight, fraction: u)
        let bottom = interpolate(corners.bottomLeft, corners.bottomRight, fraction: u)
        return interpolate(top, bottom, fraction: v)
    }

    func localSpacing() -> CGSize {
        CGSize(
            width: hypot(corners.topRight.x - corners.topLeft.x, corners.topRight.y - corners.topLeft.y) / CGFloat(lineCount - 1),
            height: hypot(corners.bottomLeft.x - corners.topLeft.x, corners.bottomLeft.y - corners.topLeft.y) / CGFloat(lineCount - 1)
        )
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }
}
