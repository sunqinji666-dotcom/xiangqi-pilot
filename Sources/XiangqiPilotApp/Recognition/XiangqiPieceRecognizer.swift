import CoreGraphics
import Foundation

enum XiangqiPieceRecognizerBackend: Equatable, Sendable {
    case localDetector(modelName: String)
    case legacyVisionFallback

    var displayName: String {
        switch self {
        case let .localDetector(modelName):
            return "本地14类检测器 · \(modelName)"
        case .legacyVisionFallback:
            return "本地14类模型未安装 · OCR/模板仅作恢复候选"
        }
    }

    var canAuthoritativelyClassifyArbitraryPosition: Bool {
        switch self {
        case .localDetector: true
        case .legacyVisionFallback: false
        }
    }
}

/// Cold-path boundary for initial midgame synchronization and exceptional
/// recovery. The real-time connected-board loop never calls this protocol;
/// it uses the 90-intersection differencer and Xiangqi rules instead.
protocol XiangqiPieceRecognizer: Sendable {
    var backend: XiangqiPieceRecognizerBackend { get }

    func recognize(
        image: CGImage,
        frameSequence: UInt64,
        geometry: RecognitionBoardGeometry,
        targetBundleIdentifier: String?
    ) async throws -> XiangqiRecognitionSnapshot
}
