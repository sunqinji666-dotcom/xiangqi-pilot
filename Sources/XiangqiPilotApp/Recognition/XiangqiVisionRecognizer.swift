import CoreGraphics
import CoreImage
import Foundation
import ImageIO
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
    /// Occupancy is intentionally independent from OCR. A selected piece can
    /// have its glyph obscured by a highlight while its circular body is still
    /// visually obvious at the intersection.
    let occupiedCells: Set<BoardCellCoordinate>
    let confidence: Double
    let warnings: [String]

    init(
        frameSequence: UInt64,
        pieces: [RecognizedPiece],
        occupiedCells: Set<BoardCellCoordinate>? = nil,
        confidence: Double,
        warnings: [String]
    ) {
        self.frameSequence = frameSequence
        self.pieces = pieces
        self.occupiedCells = occupiedCells ?? Set(pieces.map {
            BoardCellCoordinate(file: $0.file, rank: $0.rank)
        })
        self.confidence = confidence
        self.warnings = warnings
    }

    var localOccupancy: Set<BoardCellCoordinate> {
        occupiedCells.isEmpty
            ? Set(pieces.map { BoardCellCoordinate(file: $0.file, rank: $0.rank) })
            : occupiedCells
    }

    var requiresHumanReview: Bool {
        confidence < 0.985 || warnings.contains { $0.contains("帅") || $0.contains("将") }
    }

    var hasCompleteClassification: Bool {
        pieces.count == localOccupancy.count &&
        !pieces.contains(where: { $0.side == .unknown }) &&
        pieces.contains(where: { $0.kind == .general && $0.side == .red }) &&
        pieces.contains(where: { $0.kind == .general && $0.side == .black })
    }
}

/// The installed iPhone/iPad edition of 象棋巫师 renders its pieces from these
/// local PNGs.  We never copy or distribute them: when that exact application
/// is selected, they are used in-memory only to disambiguate OCR on occupied
/// intersections.  Other applications continue to use the generic recognizer.
private final class XQWizardTemplateLibrary: @unchecked Sendable {
    private struct Template {
        let side: RecognizedSide
        let kind: RecognizedPieceKind
        let pixels: [UInt8]
    }

    private let sampleSize = 24
    private lazy var templates: [Template] = loadTemplates()

    func recognize(
        image: CGImage,
        geometry: RecognitionBoardGeometry,
        occupied: Set<BoardCellCoordinate>
    ) -> [RecognizedPiece] {
        guard !templates.isEmpty else { return [] }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let horizontalSpacing = max(4, geometry.boundingBox.width * width / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * height / 9)
        let halfSize = min(horizontalSpacing, verticalSpacing) * 0.43
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var results: [RecognizedPiece] = []

        for rank in 0..<10 {
            for file in 0..<9 {
                let point = geometry.intersectionPoint(file: file, rank: rank)
                let center = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                let crop = CGRect(
                    x: center.x - halfSize,
                    y: center.y - halfSize,
                    width: halfSize * 2,
                    height: halfSize * 2
                ).intersection(bounds).integral
                guard let cellPixels = sample(image: image, crop: crop) else { continue }
                let ranked = templates.compactMap { template -> (Template, Double)? in
                    let distance = maskedDistance(template: template.pixels, candidate: cellPixels)
                    return distance.isFinite ? (template, distance) : nil
                }.sorted { $0.1 < $1.1 }
                guard let best = ranked.first else { continue }
                let margin = (ranked.dropFirst().first?.1 ?? 1) - best.1
                let coordinate = BoardCellCoordinate(file: file, rank: rank)
                // An already occupied cell needs only a good glyph match.  An
                // otherwise empty cell needs a much stronger, clearly unique
                // match so a board-line pattern can never invent a piece.
                let isOccupied = occupied.contains(coordinate)
                let accepted = isOccupied
                    ? best.1 <= 0.30 && margin >= 0.018
                    : best.1 <= 0.16 && margin >= 0.075
                guard accepted else { continue }
                let confidence = max(0.58, min(0.97, 1 - best.1 / (isOccupied ? 0.42 : 0.24)))
                results.append(RecognizedPiece(
                    file: file,
                    rank: rank,
                    side: best.0.side,
                    kind: best.0.kind,
                    confidence: confidence,
                    glyph: glyph(for: best.0.kind, side: best.0.side)
                ))
            }
        }
        return results
    }

    private func loadTemplates() -> [Template] {
        let root = URL(fileURLWithPath: "/Applications/象棋巫师.app/Wrapper/XQWizard.app", isDirectory: true)
        let definitions: [(String, RecognizedPieceKind)] = [
            ("k", .general), ("a", .advisor), ("b", .elephant),
            ("n", .horse), ("r", .chariot), ("c", .cannon),
            ("p", .soldier)
        ]
        return [RecognizedSide.black, .red].flatMap { side in
            let prefix = side == .black ? "b" : "r"
            return definitions.compactMap { definition -> Template? in
                let (suffix, kind) = definition
                let url = root.appendingPathComponent("\(prefix)\(suffix)@2x.png")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let pixels = sample(image: image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else {
                    return nil
                }
                return Template(side: side, kind: kind, pixels: pixels)
            }
        }
    }

    private func sample(image: CGImage, crop: CGRect) -> [UInt8]? {
        guard !crop.isNull, crop.width > 4, crop.height > 4,
              let source = image.cropping(to: crop) else { return nil }
        var rgba = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let context = CGContext(
            data: &rgba,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        context.draw(source, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        return rgba
    }

    private func maskedDistance(template: [UInt8], candidate: [UInt8]) -> Double {
        guard template.count == candidate.count else { return .infinity }
        var total = 0.0
        var weight = 0.0
        for offset in stride(from: 0, to: template.count, by: 4) {
            let alpha = Double(template[offset + 3]) / 255
            guard alpha > 0.12 else { continue }
            let dr = Double(template[offset]) - Double(candidate[offset])
            let dg = Double(template[offset + 1]) - Double(candidate[offset + 1])
            let db = Double(template[offset + 2]) - Double(candidate[offset + 2])
            total += (dr * dr + dg * dg + db * db) * alpha
            weight += 3 * alpha
        }
        guard weight > 1 else { return .infinity }
        return sqrt(total / weight) / 255
    }

    private func glyph(for kind: RecognizedPieceKind, side: RecognizedSide) -> String {
        switch (kind, side) {
        case (.general, .red): return "帥"
        case (.general, .black): return "將"
        case (.advisor, .red): return "仕"
        case (.advisor, .black): return "士"
        case (.elephant, .red): return "相"
        case (.elephant, .black): return "象"
        case (.horse, _): return "馬"
        case (.chariot, _): return "車"
        case (.cannon, .red): return "炮"
        case (.cannon, .black): return "砲"
        case (.soldier, .red): return "兵"
        case (.soldier, .black): return "卒"
        default: return "?"
        }
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

    /// Vision clips text at the edge of `regionOfInterest`. The calibrated
    /// quadrilateral runs through the piece centres, so pad it by half a cell
    /// to include the complete glyphs on all four outer ranks/files.
    var recognitionRegion: CGRect {
        let box = boundingBox
        return box.insetBy(
            dx: -box.width / 16,
            dy: -box.height / 18
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Vision reports text boxes relative to `regionOfInterest`, not relative
    /// to the full source image. Convert them before grid intersection lookup.
    func imagePoint(fromRegionPoint point: CGPoint, region: CGRect) -> CGPoint {
        CGPoint(
            x: region.minX + point.x * region.width,
            y: region.minY + point.y * region.height
        )
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
        "帅": (.general, .red), "帥": (.general, .red),
        "將": (.general, .black), "将": (.general, .black),
        "仕": (.advisor, .red), "士": (.advisor, .black),
        "相": (.elephant, .red), "象": (.elephant, .black),
        "兵": (.soldier, .red), "卒": (.soldier, .black),
        "馬": (.horse, .unknown), "马": (.horse, .unknown), "傌": (.horse, .red),
        "車": (.chariot, .unknown), "车": (.chariot, .unknown), "俥": (.chariot, .red),
        "炮": (.cannon, .unknown), "砲": (.cannon, .unknown),
        // Common single-glyph Vision confusions on stylized board skins. The
        // side stays unknown and is resolved from the piece colour.
        "生": (.advisor, .unknown),
        "抱": (.cannon, .unknown), "饱": (.cannon, .unknown),
        "乒": (.soldier, .unknown), "岳": (.soldier, .unknown)
    ]
    private let canonicalWords = [
        "帅", "帥", "將", "将", "仕", "士", "相", "象", "兵", "卒",
        "馬", "马", "傌", "車", "车", "俥", "炮", "砲",
        "車馬象士將士象馬車", "車馬相仕帥仕相馬車"
    ]
    private let xqWizardTemplates = XQWizardTemplateLibrary()

    func recognize(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry,
        targetBundleIdentifier: String? = nil
    ) async throws -> XiangqiRecognitionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            visionQueue.async { [self] in
                do {
                    continuation.resume(returning: try recognizeSync(
                        image: image,
                        frameSequence: frameSequence,
                        geometry: geometry,
                        targetBundleIdentifier: targetBundleIdentifier
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
        geometry: RecognitionBoardGeometry,
        targetBundleIdentifier: String?
    ) throws -> XiangqiRecognitionSnapshot {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        request.customWords = canonicalWords
        request.regionOfInterest = geometry.recognitionRegion

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let observations = request.results ?? []
        var byCell: [Int: RecognizedPiece] = [:]

        let region = request.regionOfInterest
        for observation in observations {
            guard let candidate = observation.topCandidates(3).max(by: { lhs, rhs in
                let lhsCount = lhs.string.filter { glyphMap[$0] != nil }.count
                let rhsCount = rhs.string.filter { glyphMap[$0] != nil }.count
                if lhsCount == rhsCount { return lhs.confidence < rhs.confidence }
                return lhsCount < rhsCount
            }), candidate.string.contains(where: { glyphMap[$0] != nil }) else { continue }

            for index in candidate.string.indices {
                let glyph = candidate.string[index]
                guard let (kind, inherentSide) = glyphMap[glyph] else { continue }
                let next = candidate.string.index(after: index)
                let range = index..<next
                let localBox: CGRect
                if let characterBox = try? candidate.boundingBox(for: range) {
                    localBox = characterBox.boundingBox
                } else if candidate.string.count == 1 {
                    localBox = observation.boundingBox
                } else {
                    continue
                }

                let localPoint = CGPoint(x: localBox.midX, y: localBox.midY)
                let point = geometry.imagePoint(fromRegionPoint: localPoint, region: region)
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
                if byCell[key] == nil || byCell[key]!.confidence < confidence {
                    byCell[key] = recognized
                }
            }
        }

        // Global OCR is fast, but this board skin occasionally groups a row of
        // pieces into one observation and drops individual glyphs. When that
        // happens, re-read every calibrated intersection as an independent
        // large glyph. This path runs only for an incomplete board.
        if byCell.count < 30 {
            for piece in recognizeGridCells(image: image, geometry: geometry) {
                let key = piece.rank * 9 + piece.file
                if byCell[key] == nil || byCell[key]!.confidence < piece.confidence {
                    byCell[key] = piece
                }
            }
        }

        // Template matching is only allowed to fill a cell that the independent
        // occupancy detector also sees as a real piece body.  Matching against
        // every empty intersection is unsafe on wood/line board skins: a blank
        // corner can have a patch that looks deceptively like a repeated pawn.
        // That was the source of a false red 兵 at the empty top-right corner
        // in 象棋巫师.
        let detectedOccupancy = detectOccupiedIntersections(image: image, geometry: geometry)
        if targetBundleIdentifier == "com.jpcxc.xqwiphone" {
            for piece in xqWizardTemplates.recognize(
                image: image,
                geometry: geometry,
                occupied: detectedOccupancy
            ) {
                let key = piece.rank * 9 + piece.file
                if byCell[key] == nil || byCell[key]!.confidence < piece.confidence {
                    byCell[key] = piece
                }
            }
        }
        for piece in inferRepeatedPieceTemplates(
            image: image,
            geometry: geometry,
            recognized: Array(byCell.values),
            detectedOccupancy: detectedOccupancy
        ) {
            let key = piece.rank * 9 + piece.file
            if byCell[key] == nil {
                byCell[key] = piece
            }
        }

        let pieces = byCell.values.sorted { ($0.rank, $0.file) < ($1.rank, $1.file) }
        let recognizedOccupancy = Set(pieces.map {
            BoardCellCoordinate(file: $0.file, rank: $0.rank)
        })
        let occupiedCells = detectedOccupancy
            .union(recognizedOccupancy)
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
        if occupiedCells.count != pieces.count {
            warnings.append("本地占位检测到\(occupiedCells.count)格，文字识别到\(pieces.count)枚")
        }
        let mean = pieces.isEmpty ? 0 : pieces.map(\.confidence).reduce(0, +) / Double(pieces.count)
        let completeness = min(1, Double(knownSides.count) / max(2, Double(pieces.count)))
        return XiangqiRecognitionSnapshot(
            frameSequence: frameSequence,
            pieces: pieces,
            occupiedCells: occupiedCells,
            confidence: mean * completeness,
            warnings: warnings
        )
    }

    /// Detects the pale circular body of a piece at each calibrated
    /// intersection. It does not attempt to identify the glyph. This is
    /// robust to the blue selection corners used by 象棋巫师, which can make
    /// Vision omit a character but do not turn a real piece into an empty cell.
    private func detectOccupiedIntersections(
        image: CGImage,
        geometry: RecognitionBoardGeometry
    ) -> Set<BoardCellCoordinate> {
        let ciImage = CIImage(cgImage: image)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let horizontalSpacing = max(4, geometry.boundingBox.width * width / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * height / 9)
        let spacing = min(horizontalSpacing, verticalSpacing)
        let innerHalf = spacing * 0.17
        let outerHalf = spacing * 0.31
        var occupied: Set<BoardCellCoordinate> = []

        for rank in 0..<10 {
            for file in 0..<9 {
                let point = geometry.intersectionPoint(file: file, rank: rank)
                let center = CGPoint(x: point.x * width, y: point.y * height)
                let inner = CGRect(
                    x: center.x - innerHalf,
                    y: center.y - innerHalf,
                    width: innerHalf * 2,
                    height: innerHalf * 2
                ).intersection(ciImage.extent)
                let outer = CGRect(
                    x: center.x - outerHalf,
                    y: center.y - outerHalf,
                    width: outerHalf * 2,
                    height: outerHalf * 2
                ).intersection(ciImage.extent)
                guard let innerColor = averageColor(in: ciImage, rect: inner),
                      let outerColor = averageColor(in: ciImage, rect: outer) else { continue }

                let innerLuminance = luminance(innerColor)
                let contrast = innerLuminance - luminance(outerColor)

                // A glyph can occupy most of the centre of a piece (the
                // moved black 卒 at c6/r4 is a good example), making the
                // centre itself dark. Sample a four-point annulus as well;
                // the porcelain body stays bright while a blank crossing has
                // almost no radial contrast. The samples are deliberately
                // kept inside the board so an empty corner cannot pass solely
                // because it has a bright wood background.
                let ringHalf = max(2, spacing * 0.075)
                let ringOffsets: [(CGFloat, CGFloat)] = [
                    (horizontalSpacing * 0.22, 0),
                    (-horizontalSpacing * 0.22, 0),
                    (0, verticalSpacing * 0.22),
                    (0, -verticalSpacing * 0.22)
                ]
                let bodyLuminances = ringOffsets.compactMap { dx, dy -> Double? in
                    let rect = CGRect(
                        x: center.x + dx - ringHalf,
                        y: center.y + dy - ringHalf,
                        width: ringHalf * 2,
                        height: ringHalf * 2
                    ).intersection(ciImage.extent)
                    guard let color = averageColor(in: ciImage, rect: rect) else { return nil }
                    return luminance(color)
                }
                let annulusLuminance = bodyLuminances.isEmpty
                    ? innerLuminance
                    : bodyLuminances.reduce(0, +) / Double(bodyLuminances.count)
                let annulusContrast = annulusLuminance - luminance(outerColor)
                // An empty crossing has dark grid lines at its centre, while
                // the porcelain-like centre of a piece is consistently bright.
                if (innerLuminance >= 0.62 && contrast >= 0.025) ||
                    (bodyLuminances.count >= 3 && annulusLuminance >= 0.60 && annulusContrast >= 0.025) {
                    occupied.insert(BoardCellCoordinate(file: file, rank: rank))
                }
            }
        }
        return occupied
    }

    private func recognizeGridCells(
        image: CGImage,
        geometry: RecognitionBoardGeometry
    ) -> [RecognizedPiece] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let horizontalSpacing = max(4, geometry.boundingBox.width * width / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * height / 9)
        let halfSize = min(horizontalSpacing, verticalSpacing) * 0.43
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        var pieces: [RecognizedPiece] = []

        for rank in 0..<10 {
            for file in 0..<9 {
                let point = geometry.intersectionPoint(file: file, rank: rank)
                // Recognition geometry uses Vision/Core Image coordinates
                // (bottom-left origin); CGImage cropping uses top-left.
                let center = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                let crop = CGRect(
                    x: center.x - halfSize,
                    y: center.y - halfSize,
                    width: halfSize * 2,
                    height: halfSize * 2
                ).intersection(imageBounds).integral
                guard crop.width > 12, crop.height > 12,
                      let cellImage = image.cropping(to: crop) else { continue }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
                request.usesLanguageCorrection = false
                // Small/moved pieces on the 象棋巫师 skin can be only a few
                // dozen pixels high after the window is scaled. Keep this
                // fallback local and cheap, but do not discard those glyphs.
                request.minimumTextHeight = 0.05
                request.customWords = canonicalWords
                let handler = VNImageRequestHandler(cgImage: cellImage, orientation: .up)
                guard (try? handler.perform([request])) != nil,
                      let candidates = request.results?.flatMap({ $0.topCandidates(3) }),
                      let candidate = candidates.max(by: { lhs, rhs in
                          let lhsCount = lhs.string.filter { glyphMap[$0] != nil }.count
                          let rhsCount = rhs.string.filter { glyphMap[$0] != nil }.count
                          if lhsCount == rhsCount { return lhs.confidence < rhs.confidence }
                          return lhsCount < rhsCount
                      }),
                      let glyph = candidate.string.first(where: { glyphMap[$0] != nil }),
                      let (kind, inherentSide) = glyphMap[glyph] else { continue }

                let side = inherentSide == .unknown
                    ? estimateSide(image: image, normalizedPoint: point)
                    : inherentSide
                pieces.append(RecognizedPiece(
                    file: file,
                    rank: rank,
                    side: side,
                    kind: kind,
                    confidence: Double(candidate.confidence) * (side == .unknown ? 0.75 : 1),
                    glyph: String(glyph)
                ))
            }
        }
        return pieces
    }

    /// A moved pawn can be missed by text recognition even though several
    /// identical pawns are plainly visible. Match small normalized patches
    /// against already-recognized repeated pieces; this fills only high-agreement
    /// cells and never invents a new piece type.
    private func inferRepeatedPieceTemplates(
        image: CGImage,
        geometry: RecognitionBoardGeometry,
        recognized: [RecognizedPiece],
        detectedOccupancy: Set<BoardCellCoordinate>
    ) -> [RecognizedPiece] {
        let templates = recognized.filter { $0.side != .unknown }
            .reduce(into: [String: [RecognizedPiece]]()) { groups, piece in
                groups["\(piece.side.rawValue)-\(piece.kind.rawValue)", default: []].append(piece)
            }
            .filter { $0.value.count >= 2 }
        guard !templates.isEmpty else { return [] }

        let ciImage = CIImage(cgImage: image)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let horizontalSpacing = max(4, geometry.boundingBox.width * width / 8)
        let verticalSpacing = max(4, geometry.boundingBox.height * height / 9)
        let halfSize = min(horizontalSpacing, verticalSpacing) * 0.38
        var patchCache: [BoardCellCoordinate: [Double]] = [:]
        func patch(file: Int, rank: Int) -> [Double]? {
            let coordinate = BoardCellCoordinate(file: file, rank: rank)
            if let cached = patchCache[coordinate] { return cached }
            let point = geometry.intersectionPoint(file: file, rank: rank)
            let center = CGPoint(x: point.x * width, y: point.y * height)
            let rect = CGRect(
                x: center.x - halfSize,
                y: center.y - halfSize,
                width: halfSize * 2,
                height: halfSize * 2
            ).intersection(ciImage.extent)
            guard let made = normalizedPatch(in: ciImage, rect: rect) else { return nil }
            patchCache[coordinate] = made
            return made
        }

        var inferred: [RecognizedPiece] = []
        let occupied = Set(recognized.map { BoardCellCoordinate(file: $0.file, rank: $0.rank) })
        for (key, group) in templates {
            guard let first = group.first else { continue }
            let groupPatches = group.compactMap { patch(file: $0.file, rank: $0.rank) }
            guard groupPatches.count >= 2 else { continue }
            let pairDistances = groupPatches.indices.flatMap { index in
                groupPatches.indices.dropFirst(index + 1).map {
                    patchDistance(groupPatches[index], groupPatches[$0])
                }
            }
            let baseline = pairDistances.sorted().dropFirst(pairDistances.count / 2).first ?? 0.01
            let threshold = min(0.075, max(0.018, baseline * 3.2))
            var best: (coordinate: BoardCellCoordinate, distance: Double)?
            for rank in 0..<10 {
                for file in 0..<9 {
                    let coordinate = BoardCellCoordinate(file: file, rank: rank)
                    guard detectedOccupancy.contains(coordinate),
                          !occupied.contains(coordinate),
                          let candidate = patch(file: file, rank: rank) else { continue }
                    let distance = groupPatches.map { patchDistance($0, candidate) }.min() ?? .infinity
                    if distance <= threshold,
                       best == nil || distance < best!.distance {
                        best = (coordinate, distance)
                    }
                }
            }
            guard let best else { continue }
            let confidence = max(0.55, min(0.86, 1 - best.distance / max(threshold, 0.001)))
            inferred.append(RecognizedPiece(
                file: best.coordinate.file,
                rank: best.coordinate.rank,
                side: first.side,
                kind: first.kind,
                confidence: confidence,
                glyph: glyph(for: first.kind, side: first.side)
            ))
            _ = key // Keeps grouping intent explicit in optimized builds.
        }
        return inferred
    }

    private func normalizedPatch(in image: CIImage, rect: CGRect) -> [Double]? {
        guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
        let size = 14
        let cropped = image.cropped(to: rect).transformed(by: CGAffineTransform(
            translationX: -rect.minX,
            y: -rect.minY
        ).scaledBy(x: CGFloat(size) / rect.width, y: CGFloat(size) / rect.height))
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        ciContext.render(cropped, toBitmap: &rgba, rowBytes: size * 4,
                         bounds: CGRect(x: 0, y: 0, width: size, height: size),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var values: [Double] = []
        values.reserveCapacity(size * size)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let red = Double(rgba[offset]) / 255
            let green = Double(rgba[offset + 1]) / 255
            let blue = Double(rgba[offset + 2]) / 255
            values.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        var squaredDeviation = 0.0
        for value in values {
            let delta = value - mean
            squaredDeviation += delta * delta
        }
        let variance = squaredDeviation / Double(values.count)
        let deviation = max(0.04, sqrt(variance))
        values = values.map { ($0 - mean) / deviation }
        return values
    }

    private func patchDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        return zip(lhs, rhs).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(lhs.count)
    }

    private func glyph(for kind: RecognizedPieceKind, side: RecognizedSide) -> String {
        switch (kind, side) {
        case (.general, .red): "帥"
        case (.general, .black): "將"
        case (.advisor, .red): "仕"
        case (.advisor, .black): "士"
        case (.elephant, .red): "相"
        case (.elephant, .black): "象"
        case (.horse, _): "馬"
        case (.chariot, _): "車"
        case (.cannon, .red): "炮"
        case (.cannon, .black): "砲"
        case (.soldier, .red): "兵"
        case (.soldier, .black): "卒"
        default: "?"
        }
    }

    private func averageColor(in image: CIImage, rect: CGRect) -> SIMD3<Double>? {
        guard !rect.isNull, rect.width > 1, rect.height > 1,
              let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        let cropped = image.cropped(to: rect)
        filter.setValue(cropped, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: cropped.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &rgba, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return SIMD3(Double(rgba[0]) / 255, Double(rgba[1]) / 255, Double(rgba[2]) / 255)
    }

    private func luminance(_ color: SIMD3<Double>) -> Double {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    private func estimateSide(image: CGImage, normalizedPoint: CGPoint) -> RecognizedSide {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Sample most of the piece body rather than a tiny centre square. The
        // centre is often occupied by a dark glyph, so use a moderately sized
        // average and require a colour margin instead of a hard hue label.
        let radius = max(6, min(width / 52, height / 58))
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
        if red - max(green, blue) >= 8,
           red >= green * 1.10,
           red >= blue * 1.10 {
            return .red
        }
        if max(green, blue) - red >= 4 { return .black }
        return .unknown
    }
}
