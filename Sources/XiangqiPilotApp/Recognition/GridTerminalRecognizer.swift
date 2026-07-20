import CoreGraphics
import Foundation
import Vision

enum GridTerminalResult: Equatable, Sendable {
    case win
    case loss
    case draw

    var title: String {
        switch self {
        case .win: "胜利"
        case .loss: "失败"
        case .draw: "和棋"
        }
    }
}

/// A terminal overlay is higher-confidence evidence than a changing board.
/// The local Go and Gomoku clients use explicit Chinese result labels.
enum GridTerminalRecognizer {
    static func isTerminalOverlay(text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return normalized.contains("对局结束")
            || normalized.contains("本局结束")
            || normalized.contains("游戏结束")
    }

    static func classify(text: String) -> GridTerminalResult? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if normalized.contains("失败") || normalized.contains("负") || normalized.contains("lose") { return .loss }
        if normalized.contains("胜利") || normalized.contains("获胜") || normalized.contains("win") { return .win }
        if normalized.contains("和棋") || normalized.contains("平局") || normalized.contains("draw") { return .draw }
        return nil
    }

    static func recognize(image: CGImage) -> GridTerminalResult? {
        guard let text = recognizedText(in: image) else { return nil }
        return classify(text: text)
    }

    static func recognizesTerminalOverlay(image: CGImage) -> Bool {
        guard let text = recognizedText(in: image) else { return false }
        return isTerminalOverlay(text: text)
    }

    private static func recognizedText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Result cards in the installed 五子棋 client use a large brush-like
        // Chinese display face. Vision's language correction can erase the
        // short terminal word "失败" entirely; raw accurate OCR preserves it
        // (and is still classified by our exact terminal vocabulary).
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
