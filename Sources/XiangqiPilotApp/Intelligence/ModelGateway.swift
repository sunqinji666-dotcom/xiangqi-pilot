import Foundation

actor ModelGateway {
    private var providers: [UUID: any ModelProvider] = [:]
    private var activeProviderID: UUID?
    private var generation: UInt64 = 0

    func register(_ provider: any ModelProvider, activate: Bool = false) {
        providers[provider.configuration.id] = provider
        if activate || activeProviderID == nil {
            activeProviderID = provider.configuration.id
        }
    }

    func removeProvider(id: UUID) {
        providers.removeValue(forKey: id)
        if activeProviderID == id { activeProviderID = providers.keys.first }
    }

    func activate(id: UUID) throws {
        guard providers[id] != nil else { throw ModelGatewayError.providerUnavailable }
        activeProviderID = id
        generation &+= 1
    }

    func cancelPendingRequests() {
        generation &+= 1
    }

    func perform(
        _ request: IntelligenceRequest,
        currentFrameSequence: @escaping @Sendable () async -> UInt64,
        currentStateHash: @escaping @Sendable () async -> String
    ) async throws -> IntelligenceResponse {
        guard let id = activeProviderID, let provider = providers[id] else {
            throw ModelGatewayError.providerUnavailable
        }
        if request.boardImageJPEGBase64 != nil && !provider.configuration.allowsImageUpload {
            throw ModelGatewayError.imageUploadNotAllowed
        }

        let requestGeneration = generation
        let started = ContinuousClock.now
        let response = try await provider.perform(request)
        let elapsed = started.duration(to: .now)
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1_000) +
            Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard elapsedMilliseconds <= request.deadlineMilliseconds else {
            throw ModelGatewayError.requestExpired
        }
        guard requestGeneration == generation else { throw CancellationError() }
        guard response.isStructurallyValid else { throw ModelGatewayError.malformedResponse }

        let latestSequence = await currentFrameSequence()
        let latestHash = await currentStateHash()
        guard response.requestID == request.id,
              response.frameSequence == latestSequence,
              response.stateHash == latestHash else {
            throw ModelGatewayError.staleResponse
        }
        return response
    }
}
