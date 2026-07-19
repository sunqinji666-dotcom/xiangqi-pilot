import Foundation

struct ModelCallBilling: Equatable, Sendable {
    let modelID: String
    let inputTokens: Int
    let outputTokens: Int
    let durationMilliseconds: Int
    let costCNY: Double
    let pricingUpdatedAt: Date
    let pricingSourceURL: URL
}

private struct ModelPriceTier: Sendable {
    let maximumInputTokens: Int
    let inputCNYPerMillion: Double
    let outputCNYPerMillion: Double
}

actor AlibabaPricingService {
    static let officialURL = URL(
        string: "https://help.aliyun.com/zh/model-studio/model-pricing"
    )!

    private var rates: [String: [ModelPriceTier]] = AlibabaPricingService.fallbackRates
    private var officialUpdatedAt = Date(timeIntervalSince1970: 1_784_295_746)

    /// Refreshes from Alibaba's official China-site pricing document. The
    /// bundled values are the last verified official rates, so a temporary
    /// network failure never turns a charge into an invented estimate.
    func refreshFromOfficialSite() async {
        var request = URLRequest(url: Self.officialURL)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
              let html = String(data: data, encoding: .utf8) else { return }

        if let flash = Self.parsePlainRates(
            html: html,
            model: "qwen3.6-flash",
            nextMarker: "qwen3.6-flash-2026-04-16",
            promotional: false
        ), flash.count >= 4 {
            rates["qwen3.6-flash"] = [
                ModelPriceTier(maximumInputTokens: 256_000, inputCNYPerMillion: flash[0], outputCNYPerMillion: flash[1]),
                ModelPriceTier(maximumInputTokens: 1_000_000, inputCNYPerMillion: flash[2], outputCNYPerMillion: flash[3])
            ]
        }
        if let plus = Self.parsePlainRates(
            html: html,
            model: "qwen3.7-plus",
            nextMarker: "qwen3.7-plus-2026-05-26",
            promotional: true
        ), plus.count >= 6 {
            // Each tier lists input, non-thinking output, and thinking output.
            rates["qwen3.7-plus"] = [
                ModelPriceTier(maximumInputTokens: 256_000, inputCNYPerMillion: plus[0], outputCNYPerMillion: plus[1]),
                ModelPriceTier(maximumInputTokens: 1_000_000, inputCNYPerMillion: plus[3], outputCNYPerMillion: plus[4])
            ]
        }
        if let milliseconds = Self.firstMatch(
            in: html,
            pattern: #"lastModifiedTime\\?\"?\s*:\s*(\d{13})"#
        ).flatMap(Double.init) {
            officialUpdatedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        }
    }

    func billing(
        modelID: String,
        usage: ModelTokenUsage,
        durationMilliseconds: Int
    ) -> ModelCallBilling? {
        let canonical: String
        if modelID.hasPrefix("qwen3.6-flash") {
            canonical = "qwen3.6-flash"
        } else if modelID.hasPrefix("qwen3.7-plus") {
            canonical = "qwen3.7-plus"
        } else {
            return nil
        }
        guard let modelRates = rates[canonical],
              let tier = modelRates.first(where: { usage.inputTokens <= $0.maximumInputTokens })
                ?? modelRates.last else { return nil }
        let cost = Double(usage.inputTokens) * tier.inputCNYPerMillion / 1_000_000
            + Double(usage.outputTokens) * tier.outputCNYPerMillion / 1_000_000
        return ModelCallBilling(
            modelID: modelID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            durationMilliseconds: durationMilliseconds,
            costCNY: cost,
            pricingUpdatedAt: officialUpdatedAt,
            pricingSourceURL: Self.officialURL
        )
    }

    private static let fallbackRates: [String: [ModelPriceTier]] = [
        "qwen3.6-flash": [
            ModelPriceTier(maximumInputTokens: 256_000, inputCNYPerMillion: 1.2, outputCNYPerMillion: 7.2),
            ModelPriceTier(maximumInputTokens: 1_000_000, inputCNYPerMillion: 4.8, outputCNYPerMillion: 28.8)
        ],
        // Official page lists a limited-time 20% discount for the rolling alias.
        "qwen3.7-plus": [
            ModelPriceTier(maximumInputTokens: 256_000, inputCNYPerMillion: 1.6, outputCNYPerMillion: 6.4),
            ModelPriceTier(maximumInputTokens: 1_000_000, inputCNYPerMillion: 4.8, outputCNYPerMillion: 19.2)
        ]
    ]

    private static func parsePlainRates(
        html: String,
        model: String,
        nextMarker: String,
        promotional: Bool
    ) -> [Double]? {
        guard let start = html.range(of: ">\(model)<", options: .backwards),
              let end = html.range(of: ">\(nextMarker)<", range: start.upperBound..<html.endIndex) else {
            return nil
        }
        let rawSegment = String(html[start.lowerBound..<end.lowerBound])
        let segment = rawSegment
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let pattern = promotional
            ? #"原价\s*([0-9.]+)\s*元\s*限时\s*([0-9.]+)\s*折"#
            : #"([0-9.]+)\s*元"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(segment.startIndex..., in: segment)
        let matches = regex?.matches(in: segment, range: range) ?? []
        if promotional {
            return matches.compactMap { match in
                guard let priceRange = Range(match.range(at: 1), in: segment),
                      let discountRange = Range(match.range(at: 2), in: segment),
                      let price = Double(segment[priceRange]),
                      let discount = Double(segment[discountRange]) else { return nil }
                return price * discount / 10
            }
        }
        return matches.compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: segment) else { return nil }
            return Double(segment[valueRange])
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
