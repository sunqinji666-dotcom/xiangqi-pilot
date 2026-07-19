import CoreGraphics
import CoreImage
import Foundation
import Vision

enum RecognizedSide: String, Codable, Sendable { case red, black, unknown }

enum RecognizedPieceKind: String, Codable, CaseIterable, Sendable {
    case general, advisor, elephant, horse, chariot, cannon, soldier
}

struct RecognizedPiece: Codable, Hashable, Sendable {
    let file: Int
    let rank: Int
    let side: RecognizedSide
    let kind: RecognizedPieceKind
    let confidence: Double
    let glyph: String
}

struct XiangqiRecognitionSnapshot: Codable, Sendable {
    let frameSequence: UInt64
    let pieces: [RecognizedPiece]
    let confidence: Double
    let warnings: [String]

    var requiresHumanReview: Bool {
        confidence < 0.985 || warnings.contains { $0.contains("帅") || $0.contains("将") }
    }
}

/// Four normalized points use Vision coordinates: origin at bottom-left of the captured image.
struct RecognitionBoardGeometry: Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    var boundingBox: CGRect {
        let xs = [topLeft.x, topRight.x, bottomRight.x, bottomLeft.x]
        let ys = [topLeft.y, topRight.y, bottomRight.y, bottomLeft.y]
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 1) - (xs.min() ?? 0),
                      height: (ys.max() ?? 1) - (ys.min() ?? 0))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func nearestIntersection(to point: CGPoint) -> (file: Int, rank: Int, distance: Double)? {
        var best: (Int, Int, Double)?
        for rank in 0..<10 {
            for file in 0..<9 {
                let expected = intersectionPoint(file: file, rank: rank)
                let dx = point.x - expected.x
                let dy = point.y - expected.y
                let distance = Double(sqrt(dx * dx + dy * dy))
                if best == nil || distance < best!.2 { best = (file, rank, distance) }
            }
        }
        guard let best else { return nil }
        let spacing = min(
            hypot(topRight.x - topLeft.x, topRight.y - topLeft.y) / 8,
            hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y) / 9
        )
        guard best.2 <= Double(spacing * 0.48) else { return nil }
        return best
    }

    func intersectionPoint(file: Int, rank: Int) -> CGPoint {
        bilinearPoint(u: CGFloat(file) / 8, v: CGFloat(rank) / 9)
    }

    private func bilinearPoint(u: CGFloat, v: CGFloat) -> CGPoint {
        let top = CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * u,
                          y: topLeft.y + (topRight.y - topLeft.y) * u)
        let bottom = CGPoint(x: bottomLeft.x + (bottomRight.x - bottomLeft.x) * u,
                             y: bottomLeft.y + (bottomRight.y - bottomLeft.y) * u)
        return CGPoint(x: top.x + (bottom.x - top.x) * v,
                       y: top.y + (bottom.y - top.y) * v)
    }
}

final class XiangqiVisionRecognizer: @unchecked Sendable {
    private let visionQueue = DispatchQueue(label: "xiangqi.vision.recognition", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: true])
    private let glyphMap: [Character: (RecognizedPieceKind, RecognizedSide)] = [
        "帅": (.general, .red), "將": (.general, .black), "将": (.general, .black),
        "仕": (.advisor, .red), "士": (.advisor, .black),
        "相": (.elephant, .red), "象": (.elephant, .black),
        "兵": (.soldier, .red), "卒": (.soldier, .black),
        "馬": (.horse, .unknown), "马": (.horse, .unknown), "傌": (.horse, .red),
        "車": (.chariot, .unknown), "车": (.chariot, .unknown), "俥": (.chariot, .red),
        "炮": (.cannon, .unknown), "砲": (.cannon, .unknown)
    ]

    func recognize(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry
    ) async throws -> XiangqiRecognitionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            visionQueue.async { [self] in
                do {
                    continuation.resume(returning: try recognizeSync(
                        image: image,
                        frameSequence: frameSequence,
                        geometry: geometry
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func recognizeSync(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry
    ) throws -> XiangqiRecognitionSnapshot {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        request.customWords = glyphMap.keys.map(String.init)
        request.regionOfInterest = geometry.boundingBox

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let observations = request.results ?? []
        var byCell: [Int: RecognizedPiece] = [:]

        for observation in observations {
            guard let candidate = observation.topCandidates(3).first(where: { candidate in
                candidate.string.contains { glyphMap[$0] != nil }
            }), let glyph = candidate.string.first(where: { glyphMap[$0] != nil }),
                  let (kind, inherentSide) = glyphMap[glyph] else { continue }

            let point = CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)
            guard let cell = geometry.nearestIntersection(to: point) else { continue }
            let side = inherentSide == .unknown
                ? estimateSide(image: image, normalizedPoint: point)
                : inherentSide
            let confidence = Double(candidate.confidence) * (side == .unknown ? 0.75 : 1)
            let recognized = RecognizedPiece(
                file: cell.file,
                rank: cell.rank,
                side: side,
                kind: kind,
                confidence: confidence,
                glyph: String(glyph)
            )
            let key = cell.rank * 9 + cell.file
            if byCell[key] == nil || byCell[key]!.confidence < confidence { byCell[key] = recognized }
        }

        let pieces = byCell.values.sorted { ($0.rank, $0.file) < ($1.rank, $1.file) }
        let knownSides = pieces.filter { $0.side != .unknown }
        var warnings: [String] = []
        if !pieces.contains(where: { $0.kind == .general && $0.side == .red }) {
            warnings.append("未确认红帅")
        }
        if !pieces.contains(where: { $0.kind == .general && $0.side == .black }) {
            warnings.append("未确认黑将")
        }
        if pieces.contains(where: { $0.side == .unknown }) {
            warnings.append("有棋子颜色需人工确认")
        }
        let mean = pieces.isEmpty ? 0 : pieces.map(\.confidence).reduce(0, +) / Double(pieces.count)
        let completeness = min(1, Double(knownSides.count) / max(2, Double(pieces.count)))
        return XiangqiRecognitionSnapshot(
            frameSequence: frameSequence,
            pieces: pieces,
            confidence: mean * completeness,
            warnings: warnings
        )
    }

    private func estimateSide(image: CGImage, normalizedPoint: CGPoint) -> RecognizedSide {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let radius = max(4, min(width / 90, height / 100))
        let center = CGPoint(x: normalizedPoint.x * width, y: normalizedPoint.y * height)
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return .unknown }

        let input = CIImage(cgImage: image).cropped(to: rect)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return .unknown }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return .unknown }
        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &rgba, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let red = Double(rgba[0]), green = Double(rgba[1]), blue = Double(rgba[2])
        return red > green * 1.18 && red > blue * 1.18 ? .red : .black
    }
}
