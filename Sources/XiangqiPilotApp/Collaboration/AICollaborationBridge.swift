import Darwin
import Foundation

enum AIBridgeMessageType: String, Codable, Sendable {
    case hello
    case heartbeat
    case acknowledgement
    case requestSnapshot
    case boardState
    /// A local AI operator has read the currently bound board and supplies a
    /// complete, rule-parseable FEN.  This is deliberately distinct from a
    /// normal boardState: it is an input to the cockpit, not a claim made by
    /// the cockpit's own OCR.
    case aiRecognizedPosition
    case candidateReady
    case actionRequested
    case actionReceipt
    case requestExecution
    case pause
    case resume
    case error
}

struct AIBridgeCandidate: Codable, Equatable, Sendable {
    let ucci: String
    let score: Int
    let evaluation: String
}

struct AIBridgePayload: Codable, Equatable, Sendable {
    var correlationID: String?
    var sessionID: String?
    var windowID: UInt32?
    var ownerPID: Int32?
    var applicationName: String?
    var windowTitle: String?
    var phase: String?
    var status: String?
    var fen: String?
    var moveUCCI: String?
    var sideToMove: String?
    var confidence: Double?
    var frameSequence: UInt64?
    var deadlineUptimeMilliseconds: UInt64?
    var candidates: [AIBridgeCandidate]?
    var sourceX: Double?
    var sourceY: Double?
    var destinationX: Double?
    var destinationY: Double?
    var detail: String?

    init(
        correlationID: String? = nil,
        sessionID: String? = nil,
        windowID: UInt32? = nil,
        ownerPID: Int32? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        phase: String? = nil,
        status: String? = nil,
        fen: String? = nil,
        moveUCCI: String? = nil,
        sideToMove: String? = nil,
        confidence: Double? = nil,
        frameSequence: UInt64? = nil,
        deadlineUptimeMilliseconds: UInt64? = nil,
        candidates: [AIBridgeCandidate]? = nil,
        sourceX: Double? = nil,
        sourceY: Double? = nil,
        destinationX: Double? = nil,
        destinationY: Double? = nil,
        detail: String? = nil
    ) {
        self.correlationID = correlationID
        self.sessionID = sessionID
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.phase = phase
        self.status = status
        self.fen = fen
        self.moveUCCI = moveUCCI
        self.sideToMove = sideToMove
        self.confidence = confidence
        self.frameSequence = frameSequence
        self.deadlineUptimeMilliseconds = deadlineUptimeMilliseconds
        self.candidates = candidates
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.destinationX = destinationX
        self.destinationY = destinationY
        self.detail = detail
    }
}

struct AIBridgeEnvelope: Codable, Equatable, Sendable {
    static let protocolVersion = 1

    let version: Int
    let id: String
    let type: AIBridgeMessageType
    let sentAtUnixMilliseconds: Int64
    let payload: AIBridgePayload

    init(
        id: String = UUID().uuidString,
        type: AIBridgeMessageType,
        payload: AIBridgePayload = AIBridgePayload(),
        sentAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        version = Self.protocolVersion
        self.id = id
        self.type = type
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        self.payload = payload
    }
}

enum AIBridgeLifecycleState: Equatable, Sendable {
    case stopped
    case listening
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "未启动"
        case .listening: "等待AI连接"
        case .connected: "AI已连接"
        case .failed: "桥接异常"
        }
    }
}

struct AIBridgeSnapshot: Equatable, Sendable {
    let state: AIBridgeLifecycleState
    let socketPath: String
    let connectedClients: Int
    let sentMessages: UInt64
    let receivedMessages: UInt64
    let lastRoundTripMilliseconds: Double?
    let lastMessageAt: Date?
    let lastMessageType: AIBridgeMessageType?
}

enum AIBridgeError: LocalizedError {
    case socketPathTooLong
    case createSocket(Int32)
    case bindSocket(Int32)
    case listenSocket(Int32)
    case createDirectory(Error)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "AI协同Socket路径过长"
        case let .createSocket(code): "无法创建AI协同Socket：errno=\(code)"
        case let .bindSocket(code): "无法绑定AI协同Socket：errno=\(code)"
        case let .listenSocket(code): "无法监听AI协同Socket：errno=\(code)"
        case let .createDirectory(error): "无法创建AI协同目录：\(error.localizedDescription)"
        }
    }
}

/// Local-only, persistent, newline-delimited JSON bridge. A Unix domain
/// socket avoids fixed ports, network exposure and connection setup on every
/// move. The runtime remains authoritative: incoming commands are validated
/// again against the current FEN, frame sequence and legal candidates.
final class AICollaborationBridge: @unchecked Sendable {
    typealias EnvelopeHandler = @Sendable (AIBridgeEnvelope) -> Void
    typealias StateHandler = @Sendable (AIBridgeSnapshot) -> Void

    private let ioQueue = DispatchQueue(
        label: "com.jacksun.xiangqi-pilot.ai-bridge",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var listenerFD: Int32 = -1
    private var clients: Set<Int32> = []
    private var sentAtByMessageID: [String: TimeInterval] = [:]
    private var lifecycleState: AIBridgeLifecycleState = .stopped
    private var sentMessages: UInt64 = 0
    private var receivedMessages: UInt64 = 0
    private var lastRoundTripMilliseconds: Double?
    private var lastMessageAt: Date?
    private var lastMessageType: AIBridgeMessageType?
    private var isStopping = false

    var onEnvelope: EnvelopeHandler?
    var onStateChange: StateHandler?

    let socketPath: String

    init(socketPath: String = AICollaborationBridge.defaultSocketPath()) {
        self.socketPath = socketPath
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    deinit {
        stop()
    }

    static func defaultSocketPath() -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("XiangqiPilot", isDirectory: true)
            .appendingPathComponent("ai-bridge.sock", isDirectory: false)
            .path
    }

    func start() throws {
        lock.lock()
        if listenerFD >= 0 {
            lock.unlock()
            return
        }
        isStopping = false
        lock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AIBridgeError.createDirectory(error)
        }

        let pathBytes = socketPath.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard pathBytes.count <= pathCapacity else { throw AIBridgeError.socketPathTooLong }

        unlink(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AIBridgeError.createSocket(errno) }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { bytes in
                for index in pathBytes.indices { bytes[index] = pathBytes[index] }
            }
        }
        let addressLength = socklen_t(
            MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
        )
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw AIBridgeError.bindSocket(code)
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw AIBridgeError.listenSocket(code)
        }

        lock.lock()
        listenerFD = fd
        lifecycleState = .listening
        lock.unlock()
        publishState()
        ioQueue.async { [weak self] in self?.acceptLoop(listenerFD: fd) }
    }

    func stop() {
        lock.lock()
        guard listenerFD >= 0 || !clients.isEmpty else {
            lifecycleState = .stopped
            lock.unlock()
            return
        }
        isStopping = true
        let listener = listenerFD
        listenerFD = -1
        let clientFDs = Array(clients)
        clients.removeAll()
        lifecycleState = .stopped
        lock.unlock()

        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        for client in clientFDs {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        unlink(socketPath)
        publishState()
    }

    @discardableResult
    func broadcast(_ envelope: AIBridgeEnvelope) -> Bool {
        guard let data = try? encoder.encode(envelope) else { return false }
        var packet = data
        packet.append(0x0A)

        lock.lock()
        let clientFDs = Array(clients)
        if !clientFDs.isEmpty {
            sentMessages &+= 1
            lastMessageAt = Date()
            lastMessageType = envelope.type
            sentAtByMessageID[envelope.id] = ProcessInfo.processInfo.systemUptime
            if sentAtByMessageID.count > 256 {
                sentAtByMessageID.removeValue(forKey: sentAtByMessageID.keys.first!)
            }
        }
        lock.unlock()

        var delivered = false
        for client in clientFDs {
            if writeAll(packet, to: client) {
                delivered = true
            } else {
                removeClient(client)
            }
        }
        if !clientFDs.isEmpty { publishState() }
        return delivered
    }

    func snapshot() -> AIBridgeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func acceptLoop(listenerFD: Int32) {
        while true {
            let client = Darwin.accept(listenerFD, nil, nil)
            if client < 0 {
                lock.lock()
                let shouldStop = isStopping || self.listenerFD != listenerFD
                lock.unlock()
                if shouldStop { return }
                if errno == EINTR { continue }
                fail("accept errno=\(errno)")
                return
            }
            lock.lock()
            clients.insert(client)
            lifecycleState = .connected
            lock.unlock()
            publishState()
            ioQueue.async { [weak self] in self?.readLoop(clientFD: client) }
        }
    }

    private func readLoop(clientFD: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty,
                      let envelope = try? decoder.decode(AIBridgeEnvelope.self, from: Data(line)),
                      envelope.version == AIBridgeEnvelope.protocolVersion else { continue }
                receive(envelope)
            }
        }
        removeClient(clientFD)
    }

    private func receive(_ envelope: AIBridgeEnvelope) {
        lock.lock()
        receivedMessages &+= 1
        lastMessageAt = Date()
        lastMessageType = envelope.type
        if let correlationID = envelope.payload.correlationID,
           let sentAt = sentAtByMessageID.removeValue(forKey: correlationID) {
            lastRoundTripMilliseconds = max(
                0,
                (ProcessInfo.processInfo.systemUptime - sentAt) * 1_000
            )
        }
        lock.unlock()
        publishState()
        onEnvelope?(envelope)
    }

    private func removeClient(_ clientFD: Int32) {
        lock.lock()
        let existed = clients.remove(clientFD) != nil
        if clients.isEmpty, listenerFD >= 0 { lifecycleState = .listening }
        lock.unlock()
        if existed {
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
            publishState()
        }
    }

    private func fail(_ detail: String) {
        lock.lock()
        lifecycleState = .failed(detail)
        lock.unlock()
        publishState()
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private func publishState() {
        let current = snapshot()
        onStateChange?(current)
    }

    private func snapshotLocked() -> AIBridgeSnapshot {
        AIBridgeSnapshot(
            state: lifecycleState,
            socketPath: socketPath,
            connectedClients: clients.count,
            sentMessages: sentMessages,
            receivedMessages: receivedMessages,
            lastRoundTripMilliseconds: lastRoundTripMilliseconds,
            lastMessageAt: lastMessageAt,
            lastMessageType: lastMessageType
        )
    }
}
