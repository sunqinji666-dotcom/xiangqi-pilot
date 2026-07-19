import Foundation

enum AlibabaBailianConfiguration {
    static let keychainAccount = "aliyun-bailian-default-6207523"
    static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!

    static let flashProviderID = UUID(uuidString: "85D5D2DF-6CAB-4A8D-902F-7E7FA8BA7061")!
    static let plusProviderID = UUID(uuidString: "A3AC4893-D3DA-45B8-9866-9A6FEC403430")!

    static let flash = ModelProviderConfiguration(
        id: flashProviderID,
        name: "千问 3.6 Flash（快速视觉）",
        kind: .openAICompatible,
        baseURL: endpoint,
        model: "qwen3.6-flash",
        keychainAccount: keychainAccount,
        allowsImageUpload: true,
        timeoutSeconds: 6
    )

    static let plus = ModelProviderConfiguration(
        id: plusProviderID,
        name: "千问 3.7 Plus（视觉复核）",
        kind: .openAICompatible,
        baseURL: endpoint,
        model: "qwen3.7-plus",
        keychainAccount: keychainAccount,
        allowsImageUpload: true,
        timeoutSeconds: 10
    )
}
