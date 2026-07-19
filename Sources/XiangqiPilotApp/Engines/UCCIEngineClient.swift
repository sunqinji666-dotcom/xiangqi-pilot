import Foundation

struct UCCIEngineOption: Sendable, Hashable {
    let name: String
    let value: String
}

enum XiangqiEngineProtocol: Sendable {
    case uci
    case ucci

    var initializeCommand: String { self == .uci ? "uci" : "ucci" }
    var readyResponse: String { self == .uci ? "uciok" : "ucciok" }
    func goCommand(milliseconds: Int) -> String {
        self == .uci ? "go movetime \(milliseconds)" : "go time \(milliseconds)"
    }
    func optionCommand(_ option: UCCIEngineOption) -> String {
        self == .uci
            ? "setoption name \(option.name) value \(option.value)"
            : "setoption \(option.name) \(option.value)"
    }
}

struct UCCIAnalysis: Sendable, Hashable {
    let bestMove: String
    let ponderMove: String?
    let depth: Int?
    let scoreCentipawns: Int?
    let principalVariation: [String]
}

enum UCCIEngineError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case handshakeTimeout
    case thinkingTimeout
    case malformedBestMove
    case stopped

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "没有找到 UCCI 象棋引擎"
        case .launchFailed(let reason): return "引擎启动失败：\(reason)"
        case .handshakeTimeout: return "引擎 UCCI 握手超时"
        case .thinkingTimeout: return "引擎思考超时"
        case .malformedBestMove: return "引擎返回的着法格式无效"
        case .stopped: return "引擎已停止"
        }
    }
}

actor UCCIEngineClient {
    private let executableURL: URL
    private let options: [UCCIEngineOption]
    private let engineProtocol: XiangqiEngineProtocol
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer: UCCIOutputBuffer?
    private var lastInfo = EngineInfoAccumulator()

    init(
        executableURL: URL,
        engineProtocol: XiangqiEngineProtocol = .ucci,
        options: [UCCIEngineOption] = []
    ) {
        self.executableURL = executableURL
        self.engineProtocol = engineProtocol
        self.options = options
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UCCIEngineError.executableMissing
        }
        if process?.isRunning == true { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let buffer = UCCIOutputBuffer()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe
        process.environment = sanitizedEnvironment()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        do {
            try process.run()
        } catch {
            throw UCCIEngineError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.outputBuffer = buffer

        try send(engineProtocol.initializeCommand)
        guard await waitForLine(prefix: engineProtocol.readyResponse, timeoutMilliseconds: 2_500) != nil else {
            stop()
            throw UCCIEngineError.handshakeTimeout
        }
        for option in options {
            try send(engineProtocol.optionCommand(option))
        }
        try send("isready")
        guard await waitForLine(prefix: "readyok", timeoutMilliseconds: 2_500) != nil else {
            stop()
            throw UCCIEngineError.handshakeTimeout
        }
    }

    func analyze(fen: String, moves: [String] = [], timeMilliseconds: Int) async throws -> UCCIAnalysis {
        if process?.isRunning != true { try await start() }
        guard process?.isRunning == true else { throw UCCIEngineError.stopped }

        lastInfo = EngineInfoAccumulator()
        outputBuffer?.discardPendingLines()
        let suffix = moves.isEmpty ? "" : " moves \(moves.joined(separator: " "))"
        try send("position fen \(fen)\(suffix)")
        try send(engineProtocol.goCommand(milliseconds: max(20, timeMilliseconds)))

        let timeout = max(1_000, timeMilliseconds + 1_500)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeout))
        while clock.now < deadline {
            try Task.checkCancellation()
            for line in outputBuffer?.drainLines() ?? [] {
                if line.hasPrefix("info ") { lastInfo.consume(line: line) }
                if line.hasPrefix("bestmove ") {
                    return try parseBestMove(line)
                }
            }
            try await Task.sleep(for: .milliseconds(12))
        }
        try? send("stop")
        throw UCCIEngineError.thinkingTimeout
    }

    func cancelThinking() {
        try? send("stop")
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            try? send("quit")
            process.terminate()
        }
        outputBuffer?.close()
        self.process = nil
        self.input = nil
        self.outputBuffer = nil
    }

    private func send(_ command: String) throws {
        guard let input, process?.isRunning == true else { throw UCCIEngineError.stopped }
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try input.write(contentsOf: data)
    }

    private func waitForLine(prefix: String, timeoutMilliseconds: Int) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while clock.now < deadline {
            for line in outputBuffer?.drainLines() ?? [] where line.hasPrefix(prefix) {
                return line
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
        return nil
    }

    private func parseBestMove(_ line: String) throws -> UCCIAnalysis {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2, Self.isMoveToken(tokens[1]) else {
            throw UCCIEngineError.malformedBestMove
        }
        var ponder: String?
        if let index = tokens.firstIndex(of: "ponder"), tokens.indices.contains(index + 1), Self.isMoveToken(tokens[index + 1]) {
            ponder = tokens[index + 1]
        }
        return UCCIAnalysis(
            bestMove: tokens[1],
            ponderMove: ponder,
            depth: lastInfo.depth,
            scoreCentipawns: lastInfo.score,
            principalVariation: lastInfo.pv
        )
    }

    private static func isMoveToken(_ token: String) -> Bool {
        guard token.count == 4 else { return false }
        let chars = Array(token.lowercased())
        return chars[0] >= "a" && chars[0] <= "i" && chars[2] >= "a" && chars[2] <= "i" &&
            chars[1].isNumber && chars[3].isNumber
    }

    private func sanitizedEnvironment() -> [String: String] {
        let allowed = ["PATH", "TMPDIR", "LANG"]
        return ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
    }
}

private struct EngineInfoAccumulator {
    var depth: Int?
    var score: Int?
    var pv: [String] = []

    mutating func consume(line: String) {
        let tokens = line.split(separator: " ").map(String.init)
        if let index = tokens.firstIndex(of: "depth"), tokens.indices.contains(index + 1) {
            depth = Int(tokens[index + 1])
        }
        if let index = tokens.firstIndex(of: "score"), tokens.indices.contains(index + 2) {
            score = Int(tokens[index + 2])
        }
        if let index = tokens.firstIndex(of: "pv") {
            pv = Array(tokens.dropFirst(index + 1).prefix(32))
        }
    }
}

private final class UCCIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingData = Data()
    private var lines: [String] = []

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pendingData.append(data)
        while let newline = pendingData.firstIndex(of: 0x0A) {
            let lineData = pendingData[..<newline]
            pendingData.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                lines.append(line)
            }
        }
        if lines.count > 1_000 { lines.removeFirst(lines.count - 1_000) }
    }

    func drainLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let result = lines
        lines.removeAll(keepingCapacity: true)
        return result
    }

    func discardPendingLines() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll(keepingCapacity: true)
        pendingData.removeAll(keepingCapacity: true)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        pendingData.removeAll()
    }
}
