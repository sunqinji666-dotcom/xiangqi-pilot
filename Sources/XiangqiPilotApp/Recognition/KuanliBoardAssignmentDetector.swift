import CoreGraphics
import Foundation
import XiangqiCore

struct KuanliBoardAssignment: Equatable, Sendable {
    let orientation: BoardOrientation
    let controlledSide: Side
    let confidence: Double
}

/// 宽立在匹配时随机分配红黑，但本机玩家始终在棋盘下方。
/// 检测器只读取已标定交点周围的红色/黑色字迹，不依赖 OCR、
/// 窗口位置或全屏坐标。证据不足时必须返回 nil，不猜测执棋方。
enum KuanliBoardAssignmentDetector {
    private static let openingCampCells: [(file: Int, rank: Int)] = {
        let home = (0..<9).map { ($0, 0) }
        let cannons = [(1, 2), (7, 2)]
        let soldiers = [0, 2, 4, 6, 8].map { ($0, 3) }
        return home + cannons + soldiers
    }()

    static func detect(
        image: CGImage,
        geometry: RecognitionBoardGeometry
    ) -> KuanliBoardAssignment? {
        let top = campEvidence(image: image, geometry: geometry, mirrored: false)
        let bottom = campEvidence(image: image, geometry: geometry, mirrored: true)
        guard top.samples >= 8, bottom.samples >= 8 else { return nil }

        let topRedShare = top.redInk / max(1, top.redInk + top.darkInk)
        let bottomRedShare = bottom.redInk / max(1, bottom.redInk + bottom.darkInk)
        let separation = abs(topRedShare - bottomRedShare)
        guard separation >= 0.18 else { return nil }

        let orientation: BoardOrientation = topRedShare > bottomRedShare
            ? .redAtTop
            : .redAtBottom
        return KuanliBoardAssignment(
            orientation: orientation,
            controlledSide: orientation == .redAtBottom ? .red : .black,
            confidence: min(1, separation / 0.55)
        )
    }

    private static func campEvidence(
        image: CGImage,
        geometry: RecognitionBoardGeometry,
        mirrored: Bool
    ) -> (redInk: Double, darkInk: Double, samples: Int) {
        var redInk = 0.0
        var darkInk = 0.0
        var samples = 0
        for source in openingCampCells {
            let file = mirrored ? 8 - source.file : source.file
            let rank = mirrored ? 9 - source.rank : source.rank
            guard let evidence = cellInk(
                image: image,
                geometry: geometry,
                file: file,
                rank: rank
            ) else { continue }
            // Empty or heavily occluded intersections contain too little glyph
            // ink.  Ignore them so moved pieces do not vote for either side.
            guard evidence.red + evidence.dark >= 5 else { continue }
            redInk += evidence.red
            darkInk += evidence.dark
            samples += 1
        }
        return (redInk, darkInk, samples)
    }

    private static func cellInk(
        image: CGImage,
        geometry: RecognitionBoardGeometry,
        file: Int,
        rank: Int
    ) -> (red: Double, dark: Double)? {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let horizontalSpacing = geometry.boundingBox.width * imageWidth / 8
        let verticalSpacing = geometry.boundingBox.height * imageHeight / 9
        let halfSize = max(8, min(horizontalSpacing, verticalSpacing) * 0.29)
        let point = geometry.intersectionPoint(file: file, rank: rank)
        let center = CGPoint(x: point.x * imageWidth, y: (1 - point.y) * imageHeight)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let crop = CGRect(
            x: center.x - halfSize,
            y: center.y - halfSize,
            width: halfSize * 2,
            height: halfSize * 2
        ).intersection(bounds).integral
        guard crop.width > 4, crop.height > 4,
              let source = image.cropping(to: crop) else { return nil }

        let size = 24
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &rgba,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

        var red = 0.0
        var dark = 0.0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let r = Int(rgba[offset])
            let g = Int(rgba[offset + 1])
            let b = Int(rgba[offset + 2])
            if r >= 120, r - g >= 34, r - b >= 34 {
                red += 1
            } else if r <= 92, g <= 92, b <= 92 {
                dark += 1
            }
        }
        return (red, dark)
    }
}
