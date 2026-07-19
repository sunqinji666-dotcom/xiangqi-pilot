import Foundation

struct SessionMoveRecord: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case localEngine, ucciEngine, largeModel, human }
    enum Outcome: String, Codable, Sendable { case proposed, confirmed, executed, rejected, failed }

    let id: UUID
    let ply: Int
    let timestamp: Date
    let fenBefore: String
    let move: String
    let fenAfter: String?
    let source: Source
    let confidence: Double
    let thinkingMilliseconds: Int
    let outcome: Outcome
    let note: String?

    init(
        id: UUID = UUID(),
        ply: Int,
        timestamp: Date = Date(),
        fenBefore: String,
        move: String,
        fenAfter: String? = nil,
        source: Source,
        confidence: Double,
        thinkingMilliseconds: Int,
        outcome: Outcome,
        note: String? = nil
    ) {
        self.id = id
        self.ply = ply
        self.timestamp = timestamp
        self.fenBefore = fenBefore
        self.move = move
        self.fenAfter = fenAfter
        self.source = source
        self.confidence = confidence
        self.thinkingMilliseconds = thinkingMilliseconds
        self.outcome = outcome
        self.note = note
    }
}

struct XiangqiSessionRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var targetApplicationName: String?
    var targetBundleIdentifier: String?
    var targetWindowTitle: String?
    var initialFEN: String
    var currentFEN: String
    var moves: [SessionMoveRecord]
    var events: [SessionEventRecord]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        targetApplicationName: String? = nil,
        targetBundleIdentifier: String? = nil,
        targetWindowTitle: String? = nil,
        initialFEN: String,
        currentFEN: String,
        moves: [SessionMoveRecord] = [],
        events: [SessionEventRecord] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.targetApplicationName = targetApplicationName
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetWindowTitle = targetWindowTitle
        self.initialFEN = initialFEN
        self.currentFEN = currentFEN
        self.moves = moves
        self.events = events
    }
}

struct SessionEventRecord: Codable, Identifiable, Hashable, Sendable {
    enum Level: String, Codable, Sendable { case info, success, warning, error }

    let id: UUID
    let timestamp: Date
    let level: Level
    let stage: String
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, stage: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.stage = stage
        self.message = message
    }
}

actor SessionStore {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = base.appendingPathComponent("XiangqiPilot/Sessions", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func save(_ session: XiangqiSessionRecord) throws {
        try ensureDirectory()
        var copy = session
        copy.updatedAt = Date()
        let data = try encoder.encode(copy)
        try data.write(to: fileURL(for: copy.id), options: [.atomic, .completeFileProtection])
    }

    func load(id: UUID) throws -> XiangqiSessionRecord {
        try decoder.decode(XiangqiSessionRecord.self, from: Data(contentsOf: fileURL(for: id)))
    }

    func list() throws -> [XiangqiSessionRecord] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(XiangqiSessionRecord.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func export(_ session: XiangqiSessionRecord, to url: URL) throws {
        try encoder.encode(session).write(to: url, options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
