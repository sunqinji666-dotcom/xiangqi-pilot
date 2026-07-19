import CoreGraphics
import Foundation

struct XiangqiGridPoint: Hashable, Sendable {
    /// Zero-based file from the visually leftmost line. Valid range: 0...8.
    let file: Int
    /// Zero-based rank from the visually topmost line. Valid range: 0...9.
    let rank: Int

    init(file: Int, rank: Int) throws {
        guard (0...8).contains(file), (0...9).contains(rank) else {
            throw BoardCalibrationError.gridPointOutOfRange(file: file, rank: rank)
        }
        self.file = file
        self.rank = rank
    }
}

struct BoardCorners: Hashable, Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
}

enum BoardCalibrationError: LocalizedError, Equatable {
    case invalidImageSize
    case invalidWindowFrame
    case degenerateBoard
    case cornerOutsideImage
    case gridPointOutOfRange(file: Int, rank: Int)
    case pointOutsideBoardROI

    var errorDescription: String? {
        switch self {
        case .invalidImageSize:
            return "校准图像尺寸无效"
        case .invalidWindowFrame:
            return "校准窗口尺寸无效"
        case .degenerateBoard:
            return "棋盘四角无法构成有效四边形"
        case .cornerOutsideImage:
            return "棋盘角点位于捕获图像之外"
        case let .gridPointOutOfRange(file, rank):
            return "棋盘坐标越界：file=\(file), rank=\(rank)"
        case .pointOutsideBoardROI:
            return "映射坐标不在棋盘安全区域内"
        }
    }
}

/// Geometry-only calibration for an arbitrary Xiangqi position. It makes no
/// assumption about which pieces are present, whose turn it is, or board
/// orientation. Files/ranks are always expressed in visual left-to-right and
/// top-to-bottom order; the rules layer owns red/black orientation.
struct BoardCalibration: Hashable, Sendable {
    static let fileCount = 9
    static let rankCount = 10

    let corners: BoardCorners
    let imageSize: CGSize
    let windowFrame: CGRect
    let geometryHash: String

    init(corners: BoardCorners, imageSize: CGSize, windowFrame: CGRect) throws {
        guard imageSize.width > 1, imageSize.height > 1 else {
            throw BoardCalibrationError.invalidImageSize
        }
        guard windowFrame.width > 1, windowFrame.height > 1 else {
            throw BoardCalibrationError.invalidWindowFrame
        }

        let imageBounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: -0.5, dy: -0.5)
        let points = [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
        guard points.allSatisfy(imageBounds.contains) else {
            throw BoardCalibrationError.cornerOutsideImage
        }
        guard Self.isConvex(points), abs(Self.signedArea(points)) >= 64 else {
            throw BoardCalibrationError.degenerateBoard
        }

        self.corners = corners
        self.imageSize = imageSize
        self.windowFrame = windowFrame
        self.geometryHash = Self.makeGeometryHash(
            corners: corners,
            imageSize: imageSize,
            windowFrame: windowFrame
        )
    }

    /// Reuses normalized corner positions after a pure window move/resize. The
    /// caller must only use this when the captured board content scaled with the
    /// window; otherwise a fresh visual calibration is required.
    func recalibrated(imageSize newImageSize: CGSize, windowFrame newWindowFrame: CGRect) throws -> BoardCalibration {
        let normalized = BoardCorners(
            topLeft: normalize(corners.topLeft),
            topRight: normalize(corners.topRight),
            bottomLeft: normalize(corners.bottomLeft),
            bottomRight: normalize(corners.bottomRight)
        )
        let scaled = BoardCorners(
            topLeft: denormalize(normalized.topLeft, into: newImageSize),
            topRight: denormalize(normalized.topRight, into: newImageSize),
            bottomLeft: denormalize(normalized.bottomLeft, into: newImageSize),
            bottomRight: denormalize(normalized.bottomRight, into: newImageSize)
        )
        return try BoardCalibration(corners: scaled, imageSize: newImageSize, windowFrame: newWindowFrame)
    }

    func imagePoint(for gridPoint: XiangqiGridPoint) -> CGPoint {
        let u = CGFloat(gridPoint.file) / CGFloat(Self.fileCount - 1)
        let v = CGFloat(gridPoint.rank) / CGFloat(Self.rankCount - 1)
        let top = Self.interpolate(corners.topLeft, corners.topRight, fraction: u)
        let bottom = Self.interpolate(corners.bottomLeft, corners.bottomRight, fraction: u)
        return Self.interpolate(top, bottom, fraction: v)
    }

    func globalScreenPoint(for gridPoint: XiangqiGridPoint) throws -> CGPoint {
        let point = imagePoint(for: gridPoint)
        guard containsInBoardROI(point, tolerance: 1) else {
            throw BoardCalibrationError.pointOutsideBoardROI
        }

        return CGPoint(
            x: windowFrame.minX + point.x * windowFrame.width / imageSize.width,
            y: windowFrame.minY + point.y * windowFrame.height / imageSize.height
        )
    }

    func containsInBoardROI(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let polygon = [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
        if Self.contains(point, polygon: polygon) {
            return true
        }
        guard tolerance > 0 else { return false }
        return polygon.indices.contains { index in
            let next = polygon[(index + 1) % polygon.count]
            return Self.distance(from: point, toSegmentFrom: polygon[index], to: next) <= tolerance
        }
    }

    func matches(windowFrame other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(windowFrame.minX - other.minX) <= tolerance
            && abs(windowFrame.minY - other.minY) <= tolerance
            && abs(windowFrame.width - other.width) <= tolerance
            && abs(windowFrame.height - other.height) <= tolerance
    }

    private func normalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height)
    }

    private func denormalize(_ point: CGPoint, into size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }

    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count > 2 else { return 0 }
        return polygon.indices.reduce(into: CGFloat.zero) { area, index in
            let next = polygon[(index + 1) % polygon.count]
            area += polygon[index].x * next.y - next.x * polygon[index].y
        } / 2
    }

    private static func isConvex(_ polygon: [CGPoint]) -> Bool {
        guard polygon.count == 4 else { return false }
        var expectedSign: CGFloat?
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let c = polygon[(index + 2) % polygon.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 0.001 else { return false }
            let sign: CGFloat = cross > 0 ? 1 : -1
            if let expectedSign, expectedSign != sign { return false }
            expectedSign = sign
        }
        return true
    }

    private static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let crosses = (a.y > point.y) != (b.y > point.y)
                && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if crosses { inside.toggle() }
            previous = current
        }
        return inside
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(
            0,
            min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength)
        )
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private static func makeGeometryHash(
        corners: BoardCorners,
        imageSize: CGSize,
        windowFrame: CGRect
    ) -> String {
        let values = [
            corners.topLeft.x, corners.topLeft.y,
            corners.topRight.x, corners.topRight.y,
            corners.bottomLeft.x, corners.bottomLeft.y,
            corners.bottomRight.x, corners.bottomRight.y,
            imageSize.width, imageSize.height,
            windowFrame.minX, windowFrame.minY,
            windowFrame.width, windowFrame.height
        ]

        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in values {
            let quantized = Int64((value * 1_000).rounded())
            var bits = UInt64(bitPattern: quantized)
            for _ in 0..<8 {
                hash ^= bits & 0xff
                hash &*= 1_099_511_628_211
                bits >>= 8
            }
        }
        return String(format: "%016llx", hash)
    }
}
