import Foundation

enum IntelligenceTask: String, Codable, CaseIterable, Sendable {
    case recognizePosition = "recognize_position"
    case recoverInterface = "recover_interface"
    case explainMove = "explain_move"
    case calibrateBoard = "calibrate_board"
}

enum IntelligenceMode: String, Codable, CaseIterable, Sendable {
    case fast
    case balanced
    case smart

    var displayName: String {
        switch self {
        case .fast: return "极速"
        case .balanced: return "均衡"
        case .smart: return "智慧"
        }
    }
}

struct IntelligenceRequest: Codable, Sendable {
    let id: UUID
    let task: IntelligenceTask
    let game: String
    let frameSequence: UInt64
    let stateHash: String
    let deadlineMilliseconds: Int
    let positionFEN: String?
    let legalMoves: [String]
    let boardImageJPEGBase64: String?
    let context: [String: String]

    init(
        id: UUID = UUID(),
        task: IntelligenceTask,
        frameSequence: UInt64,
        stateHash: String,
        deadlineMilliseconds: Int,
        positionFEN: String? = nil,
        legalMoves: [String] = [],
        boardImageJPEGBase64: String? = nil,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.task = task
        self.game = "xiangqi"
        self.frameSequence = frameSequence
        self.stateHash = stateHash
        self.deadlineMilliseconds = deadlineMilliseconds
        self.positionFEN = positionFEN
        self.legalMoves = legalMoves
        self.boardImageJPEGBase64 = boardImageJPEGBase64
        self.context = context
    }
}

struct IntelligenceResponse: Codable, Sendable {
    let requestID: UUID
    let frameSequence: UInt64
    let stateHash: String
    let confidence: Double
    let recognizedFEN: String?
    let suggestedMove: String?
    let explanation: String?
    let warnings: [String]

    var isStructurallyValid: Bool {
        confidence.isFinite && (0...1).contains(confidence)
    }
}

struct ModelProviderConfiguration: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openAICompatible
        case openAIResponses
        case localHTTP
    }

    let id: UUID
    var name: String
    var kind: Kind
    var baseURL: URL
    var model: String
    var keychainAccount: String?
    var allowsImageUpload: Bool
    var timeoutSeconds: Double

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        baseURL: URL,
        model: String,
        keychainAccount: String? = nil,
        allowsImageUpload: Bool = false,
        timeoutSeconds: Double = 8
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.keychainAccount = keychainAccount
        self.allowsImageUpload = allowsImageUpload
        self.timeoutSeconds = timeoutSeconds
    }
}

enum ModelGatewayError: LocalizedError {
    case providerUnavailable
    case imageUploadNotAllowed
    case requestExpired
    case staleResponse
    case malformedResponse
    case remoteStatus(Int)
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .providerUnavailable: return "没有可用的大模型提供商"
        case .imageUploadNotAllowed: return "当前配置未授权上传棋盘图像"
        case .requestExpired: return "模型请求已超过本回合时限"
        case .staleResponse: return "模型结果已与最新局面不符"
        case .malformedResponse: return "模型未返回有效的象棋 JSON"
        case .remoteStatus(let code): return "模型服务返回 HTTP \(code)"
        case .missingCredential: return "没有找到该模型的 API Key"
        }
    }
}

protocol ModelProvider: Sendable {
    var configuration: ModelProviderConfiguration { get }
    func healthCheck() async -> Bool
    func perform(_ request: IntelligenceRequest) async throws -> IntelligenceResponse
}
