import CoreGraphics
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
    func signature(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry
    ) -> BoardFrameSignature {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let horizontalSpacing = max(4, geometry.boundingBox.width * imageWidth / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * imageHeight / 9)
        let radius = min(horizontalSpacing, verticalSpacing) * 0.28
        var cells: [BoardCellCoordinate: CellVisualFingerprint] = [:]

        for rank in 0..<10 {
            for file in 0..<9 {
                let normalized = geometry.intersectionPoint(file: file, rank: rank)
                // Recognition geometry is expressed in Vision/Core Image
                // coordinates (origin at bottom-left), while CGImage cropping
                // uses pixel coordinates from the top-left. Without this
                // inversion every changed intersection is attributed to the
                // vertically mirrored rank: initial symmetric positions look
                // fine, but the first real move can never match a legal move.
                let center = CGPoint(
                    x: normalized.x * imageWidth,
                    y: (1 - normalized.y) * imageHeight
                )
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                    .intersection(imageBounds)
                guard let fingerprint = averageFingerprint(in: image, rect: rect) else { continue }
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

    private func averageFingerprint(in image: CGImage, rect: CGRect) -> CellVisualFingerprint? {
        guard !rect.isNull, rect.width > 1, rect.height > 1,
              let cropped = image.cropping(to: rect.integral) else { return nil }
        let sampleSize = 4
        var rgba = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        rgba.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: sampleSize * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        }
        let pixelCount = Double(sampleSize * sampleSize)
        func channelAverage(offset: Int) -> Double {
            var total = 0.0
            for index in Swift.stride(from: offset, to: rgba.count, by: 4) {
                total += Double(rgba[index])
            }
            return total / 255 / pixelCount
        }
        let r = channelAverage(offset: 0)
        let g = channelAverage(offset: 1)
        let b = channelAverage(offset: 2)
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
