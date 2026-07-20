import CoreGraphics
import Foundation
import XiangqiCore

struct GridStoneRecognitionSnapshot: Sendable {
    let stones: [GridCoordinate: GridStone]
    let confidence: Double
    let occupancyConfidence: [GridCoordinate: Double]
}

/// Local colour/contrast recognizer for polished 2D board clients.  It samples
/// the centre disc at each calibrated intersection instead of OCRing symbols.
/// Ambiguous intersections are left empty and can be escalated to the existing
/// cloud model path rather than inventing a stone.
enum GridStoneRecognizer {
    static func recognize(image: CGImage, calibration: GridBoardCalibration) -> GridStoneRecognitionSnapshot {
        let spacing = calibration.localSpacing()
        let radius = max(3, min(spacing.width, spacing.height) * 0.30)
        var stones: [GridCoordinate: GridStone] = [:]
        var confidenceByPoint: [GridCoordinate: Double] = [:]
        var totalConfidence = 0.0
        let total = Double(calibration.lineCount * calibration.lineCount)

        for row in 0..<calibration.lineCount {
            for column in 0..<calibration.lineCount {
                let coordinate = GridCoordinate(column: column, row: row)
                guard let center = try? calibration.imagePoint(for: coordinate),
                      let sample = sample(image: image, center: center, radius: radius) else { continue }
                let result = classify(sample)
                confidenceByPoint[coordinate] = result.confidence
                totalConfidence += result.confidence
                if let stone = result.stone { stones[coordinate] = stone }
            }
        }
        return GridStoneRecognitionSnapshot(
            stones: stones,
            confidence: total == 0 ? 0 : totalConfidence / total,
            occupancyConfidence: confidenceByPoint
        )
    }

    private struct Sample {
        let red: Double
        let green: Double
        let blue: Double
        let luminance: Double
        let saturation: Double
        let darkFraction: Double
        let brightNeutralFraction: Double
        let ringDarkFraction: Double
        let ringBrightNeutralFraction: Double
    }

    private static func classify(_ sample: Sample) -> (stone: GridStone?, confidence: Double) {
        // A black stone is materially darker than the wood/green board.  Some
        // clients draw the most-recent stone with a pale centre marker or a
        // specular highlight, which can reduce its dark-pixel share below the
        // plain-disc threshold.  The low-saturation guard admits that marked
        // black stone without mistaking the warm, dark wooden border/star
        // points for a piece.
        // Last-move overlays are usually centred on the disc. Classify from
        // the outer disc ring first: a marked white stone still has a bright
        // rim, while a marked black stone keeps a dark rim.
        let ringWhiteStone = sample.ringBrightNeutralFraction >= 0.42
        if ringWhiteStone {
            return (.white, min(1, max(sample.ringBrightNeutralFraction, sample.brightNeutralFraction)))
        }
        // Wooden star points are deliberately dark but noticeably warm/brown.
        // Treating raw darkness as a black stone made a fresh 15-line board
        // look like five illegal black moves.  A real black disc remains
        // low-saturation even with its glossy highlight, so require that
        // neutral profile for every black-stone route.
        let neutralDarkStone = (sample.darkFraction >= 0.50 || sample.ringDarkFraction >= 0.52)
            && sample.saturation < 0.18
        let veryDarkNeutralStone = sample.luminance < 0.22 && sample.saturation < 0.22
        if (sample.darkFraction >= 0.60 && sample.saturation < 0.22)
            || neutralDarkStone
            || veryDarkNeutralStone {
            return (.black, min(1, max(sample.darkFraction, (0.34 - sample.luminance) / 0.34)))
        }
        // White stones are bright and near-neutral; warm board backgrounds are
        // bright too, but have significantly higher saturation.
        // Tencent Go marks the most recent white stone with a dark wedge. The
        // stone remains predominately bright and neutral, but no longer meets
        // the old 48% all-white threshold. Admit that marked-white profile
        // without weakening black detection: it still needs a substantial
        // bright-neutral share plus a high mean luminance.
        let markedWhiteStone = sample.brightNeutralFraction >= 0.28
            && sample.luminance > 0.50
            && sample.saturation < 0.18
        if sample.brightNeutralFraction >= 0.48
            || markedWhiteStone
            || (sample.luminance > 0.72 && sample.saturation < 0.18) {
            return (.white, min(1, max(sample.brightNeutralFraction, (sample.luminance - 0.60) / 0.40)))
        }
        let emptyConfidence = min(1, max(0.35, sample.saturation * 1.2 + (0.68 - abs(sample.luminance - 0.55))))
        return (nil, emptyConfidence)
    }

    private static func sample(image: CGImage, center: CGPoint, radius: CGFloat) -> Sample? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            .integral.intersection(bounds)
        guard rect.width >= 3, rect.height >= 3, let cropped = image.cropping(to: rect) else { return nil }
        let side = 12
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var red = 0.0, green = 0.0, blue = 0.0, dark = 0.0, brightNeutral = 0.0
        var ringDark = 0.0, ringBrightNeutral = 0.0, ringCount = 0.0
        let count = Double(side * side)
        for pixel in 0..<(side * side) {
            let index = pixel * 4
            let r = Double(rgba[index]) / 255
            let g = Double(rgba[index + 1]) / 255
            let b = Double(rgba[index + 2]) / 255
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let saturation = max(r, g, b) - min(r, g, b)
            red += r; green += g; blue += b
            if luminance < 0.28 { dark += 1 }
            if luminance > 0.76 && saturation < 0.16 { brightNeutral += 1 }
            let x = Double(pixel % side) - Double(side - 1) / 2
            let y = Double(pixel / side) - Double(side - 1) / 2
            let radius = hypot(x, y) / (Double(side) / 2)
            if radius >= 0.38 && radius <= 0.92 {
                ringCount += 1
                if luminance < 0.28 { ringDark += 1 }
                if luminance > 0.76 && saturation < 0.16 { ringBrightNeutral += 1 }
            }
        }
        red /= count; green /= count; blue /= count
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return Sample(
            red: red, green: green, blue: blue,
            luminance: luminance,
            saturation: max(red, green, blue) - min(red, green, blue),
            darkFraction: dark / count,
            brightNeutralFraction: brightNeutral / count,
            ringDarkFraction: ringCount == 0 ? 0 : ringDark / ringCount,
            ringBrightNeutralFraction: ringCount == 0 ? 0 : ringBrightNeutral / ringCount
        )
    }
}
