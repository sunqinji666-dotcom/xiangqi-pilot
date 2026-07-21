import CoreGraphics
import Foundation

/// A durable, local-only description of a calibrated board client.  It is a
/// replacement for opaque coordinate scripts: every profile declares which
/// client it belongs to and stores normalized geometry, never absolute screen
/// coordinates or a window ID that can go stale after a relaunch.
struct BoardConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let target: BoardConnectionTarget
    var geometry: NormalizedBoardGeometry
    var gameIdentifier: String
    var orientation: BoardProfileOrientation
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        target: BoardConnectionTarget,
        geometry: NormalizedBoardGeometry,
        gameIdentifier: String = "xiangqi",
        orientation: BoardProfileOrientation = .redAtBottom,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw BoardConnectionProfileError.emptyName }
        let normalizedGameIdentifier = gameIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGameIdentifier.isEmpty else { throw BoardConnectionProfileError.emptyGameIdentifier }

        self.id = id
        self.name = normalizedName
        self.target = target
        self.geometry = geometry
        self.gameIdentifier = normalizedGameIdentifier
        self.orientation = orientation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, target, geometry, gameIdentifier, orientation, createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            target: try container.decode(BoardConnectionTarget.self, forKey: .target),
            geometry: try container.decode(NormalizedBoardGeometry.self, forKey: .geometry),
            gameIdentifier: try container.decode(String.self, forKey: .gameIdentifier),
            orientation: try container.decode(BoardProfileOrientation.self, forKey: .orientation),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

/// A client fingerprint deliberately favors false negatives over reusing a
/// calibration for the wrong window.  A profile only matches when every
/// fingerprint field it declares also agrees with the live target.
struct BoardConnectionTarget: Codable, Hashable, Sendable {
    let bundleIdentifier: String?
    let windowTitleHint: String?
    let adapterIdentifier: String?

    init(
        bundleIdentifier: String? = nil,
        windowTitleHint: String? = nil,
        adapterIdentifier: String? = nil
    ) throws {
        let bundleIdentifier = Self.normalized(bundleIdentifier)
        let windowTitleHint = Self.normalized(windowTitleHint)
        let adapterIdentifier = Self.normalized(adapterIdentifier)
        guard bundleIdentifier != nil || windowTitleHint != nil || adapterIdentifier != nil else {
            throw BoardConnectionProfileError.missingTargetIdentity
        }
        self.bundleIdentifier = bundleIdentifier
        self.windowTitleHint = windowTitleHint
        self.adapterIdentifier = adapterIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, windowTitleHint, adapterIdentifier
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            windowTitleHint: try container.decodeIfPresent(String.self, forKey: .windowTitleHint),
            adapterIdentifier: try container.decodeIfPresent(String.self, forKey: .adapterIdentifier)
        )
    }

    func matchScore(for context: BoardConnectionTargetContext) -> Int? {
        var score = 0

        if let bundleIdentifier {
            guard bundleIdentifier.caseInsensitiveCompare(context.bundleIdentifier ?? "") == .orderedSame else {
                return nil
            }
            score += 100
        }
        if let adapterIdentifier {
            guard adapterIdentifier.caseInsensitiveCompare(context.adapterIdentifier ?? "") == .orderedSame else {
                return nil
            }
            score += 80
        }
        if let windowTitleHint {
            let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            if title.caseInsensitiveCompare(windowTitleHint) == .orderedSame {
                score += 40
            } else if title.localizedCaseInsensitiveContains(windowTitleHint) {
                score += 20
            } else {
                return nil
            }
        }

        return score == 0 ? nil : score
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BoardConnectionTargetContext: Hashable, Sendable {
    let bundleIdentifier: String?
    let windowTitle: String?
    let adapterIdentifier: String?
    let gameIdentifier: String?

    init(
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        adapterIdentifier: String? = nil,
        gameIdentifier: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.adapterIdentifier = adapterIdentifier
        self.gameIdentifier = gameIdentifier
    }
}

enum BoardProfileOrientation: String, Codable, CaseIterable, Sendable {
    case redAtBottom
    case redAtTop
}

struct NormalizedBoardPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw BoardConnectionProfileError.pointOutsideNormalizedImage
        }
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func point(in imageSize: CGSize) -> CGPoint {
        CGPoint(x: x * imageSize.width, y: y * imageSize.height)
    }
}

/// Four normalized intersections in visual image coordinates.  Keeping them
/// normalized means a pure window move or a proportional screenshot resize
/// can recover a fresh `BoardCalibration` without persisting screen points.
struct NormalizedBoardGeometry: Codable, Hashable, Sendable {
    let topLeft: NormalizedBoardPoint
    let topRight: NormalizedBoardPoint
    let bottomLeft: NormalizedBoardPoint
    let bottomRight: NormalizedBoardPoint

    init(
        topLeft: NormalizedBoardPoint,
        topRight: NormalizedBoardPoint,
        bottomLeft: NormalizedBoardPoint,
        bottomRight: NormalizedBoardPoint
    ) throws {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        guard Self.isConvex(points), abs(Self.signedArea(points)) >= 0.01 else {
            throw BoardConnectionProfileError.degenerateGeometry
        }
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    private enum CodingKeys: String, CodingKey {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            topLeft: try container.decode(NormalizedBoardPoint.self, forKey: .topLeft),
            topRight: try container.decode(NormalizedBoardPoint.self, forKey: .topRight),
            bottomLeft: try container.decode(NormalizedBoardPoint.self, forKey: .bottomLeft),
            bottomRight: try container.decode(NormalizedBoardPoint.self, forKey: .bottomRight)
        )
    }

    func makeCalibration(imageSize: CGSize, windowFrame: CGRect) throws -> BoardCalibration {
        try BoardCalibration(
            corners: BoardCorners(
                topLeft: topLeft.point(in: imageSize),
                topRight: topRight.point(in: imageSize),
                bottomLeft: bottomLeft.point(in: imageSize),
                bottomRight: bottomRight.point(in: imageSize)
            ),
            imageSize: imageSize,
            windowFrame: windowFrame
        )
    }

    private static func signedArea(_ points: [NormalizedBoardPoint]) -> Double {
        guard points.count == 4 else { return 0 }
        return points.indices.reduce(into: 0.0) { area, index in
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    private static func isConvex(_ points: [NormalizedBoardPoint]) -> Bool {
        guard points.count == 4 else { return false }
        var expectedSign: Double?
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 0.000_001 else { return false }
            let sign = cross > 0 ? 1.0 : -1.0
            if let expectedSign, expectedSign != sign { return false }
            expectedSign = sign
        }
        return true
    }
}

enum BoardConnectionProfileError: LocalizedError, Equatable {
    case emptyName
    case emptyGameIdentifier
    case missingTargetIdentity
    case pointOutsideNormalizedImage
    case degenerateGeometry

    var errorDescription: String? {
        switch self {
        case .emptyName: "连线方案名称不能为空"
        case .emptyGameIdentifier: "棋类标识不能为空"
        case .missingTargetIdentity: "连线方案至少需要应用、窗口标题或适配器标识"
        case .pointOutsideNormalizedImage: "棋盘角点必须位于图像范围内"
        case .degenerateGeometry: "棋盘四角无法构成有效四边形"
        }
    }
}

/// Local persistence for named connection schemes.  Profiles remain entirely
/// on the device and deliberately store no screenshots, account data, or
/// absolute cursor positions.
actor BoardConnectionProfileStore {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = base.appendingPathComponent("XiangqiPilot/ConnectionProfiles", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func save(_ profile: BoardConnectionProfile) throws -> BoardConnectionProfile {
        try ensureDirectory()
        var persisted = profile
        persisted.updatedAt = Date()
        try encoder.encode(persisted).write(
            to: fileURL(for: persisted.id),
            options: [.atomic, .completeFileProtection]
        )
        return persisted
    }

    func load(id: UUID) throws -> BoardConnectionProfile {
        try decoder.decode(BoardConnectionProfile.self, from: Data(contentsOf: fileURL(for: id)))
    }

    func list() throws -> [BoardConnectionProfile] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(BoardConnectionProfile.self, from: data)
        }.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.updatedAt > rhs.updatedAt
        }
    }

    func bestMatch(for context: BoardConnectionTargetContext) throws -> BoardConnectionProfile? {
        try list()
            .compactMap { profile -> (profile: BoardConnectionProfile, score: Int)? in
                guard profile.gameIdentifier.caseInsensitiveCompare(context.gameIdentifier ?? "") == .orderedSame else {
                    return nil
                }
                guard let score = profile.target.matchScore(for: context) else { return nil }
                return (profile, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.profile.updatedAt != rhs.profile.updatedAt { return lhs.profile.updatedAt > rhs.profile.updatedAt }
                return lhs.profile.id.uuidString < rhs.profile.id.uuidString
            }
            .first?.profile
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
