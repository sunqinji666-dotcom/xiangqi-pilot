import CoreGraphics
import CoreImage
import Foundation

struct BoardCellCoordinate: Codable, Hashable, Sendable {
    let file: Int
    let rank: Int
}

struct CellVisualFingerprint: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let luminance: Double

    func distance(to other: CellVisualFingerprint) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        let dl = luminance - other.luminance
        return sqrt(dr * dr + dg * dg + db * db + dl * dl * 0.65)
    }
}

struct BoardFrameSignature: Sendable {
    let frameSequence: UInt64
    let capturedAt: ContinuousClock.Instant
    let cells: [BoardCellCoordinate: CellVisualFingerprint]
}

struct BoardVisualChange: Sendable {
    let fromFrameSequence: UInt64
    let toFrameSequence: UInt64
    let cells: [(coordinate: BoardCellCoordinate, score: Double)]

    var likelyMoveEndpoints: [BoardCellCoordinate] {
        Array(cells.prefix(4).map(\.coordinate))
    }
}

final class BoardFrameDifferencer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: true])

    func signature(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry
    ) -> BoardFrameSignature {
        let ciImage = CIImage(cgImage: image)
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let horizontalSpacing = max(4, geometry.boundingBox.width * imageWidth / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * imageHeight / 9)
        let radius = min(horizontalSpacing, verticalSpacing) * 0.28
        var cells: [BoardCellCoordinate: CellVisualFingerprint] = [:]

        for rank in 0..<10 {
            for file in 0..<9 {
                let normalized = geometry.intersectionPoint(file: file, rank: rank)
                let center = CGPoint(x: normalized.x * imageWidth, y: normalized.y * imageHeight)
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                    .intersection(ciImage.extent)
                guard let fingerprint = averageFingerprint(in: ciImage, rect: rect) else { continue }
                cells[BoardCellCoordinate(file: file, rank: rank)] = fingerprint
            }
        }
        return BoardFrameSignature(frameSequence: frameSequence, capturedAt: .now, cells: cells)
    }

    func changes(
        from old: BoardFrameSignature,
        to new: BoardFrameSignature,
        minimumScore: Double = 0.07
    ) -> BoardVisualChange {
        let changed = new.cells.compactMap { coordinate, fingerprint -> (BoardCellCoordinate, Double)? in
            guard let previous = old.cells[coordinate] else { return nil }
            let score = previous.distance(to: fingerprint)
            return score >= minimumScore ? (coordinate, score) : nil
        }.sorted { $0.1 > $1.1 }
        return BoardVisualChange(
            fromFrameSequence: old.frameSequence,
            toFrameSequence: new.frameSequence,
            cells: changed
        )
    }

    private func averageFingerprint(in image: CIImage, rect: CGRect) -> CellVisualFingerprint? {
        guard !rect.isNull, rect.width > 1, rect.height > 1,
              let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image.cropped(to: rect), forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &rgba, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Double(rgba[0]) / 255
        let g = Double(rgba[1]) / 255
        let b = Double(rgba[2]) / 255
        return CellVisualFingerprint(
            red: r,
            green: g,
            blue: b,
            luminance: 0.2126 * r + 0.7152 * g + 0.0722 * b
        )
    }
}

actor StableFrameGate {
    private var lastSignature: BoardFrameSignature?
    private var stableSince: ContinuousClock.Instant?
    private let differencer: BoardFrameDifferencer

    init(differencer: BoardFrameDifferencer = BoardFrameDifferencer()) {
        self.differencer = differencer
    }

    func ingest(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry,
        settleMilliseconds: Int = 120
    ) -> BoardFrameSignature? {
        let signature = differencer.signature(image: image, frameSequence: frameSequence, geometry: geometry)
        guard let previous = lastSignature else {
            lastSignature = signature
            stableSince = .now
            return nil
        }
        let materialChange = !differencer.changes(from: previous, to: signature, minimumScore: 0.035).cells.isEmpty
        lastSignature = signature
        if materialChange {
            stableSince = .now
            return nil
        }
        guard let stableSince,
              stableSince.duration(to: .now) >= .milliseconds(settleMilliseconds) else { return nil }
        return signature
    }

    func reset() {
        lastSignature = nil
        stableSince = nil
    }
}
