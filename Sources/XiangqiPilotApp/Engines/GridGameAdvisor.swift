import Foundation
import XiangqiCore

struct GridGameRecommendation: Equatable, Sendable {
    let coordinate: GridCoordinate?
    let notation: String
    let score: Int
    let reason: String
}

enum GridGameAdvisor {
    static func gomoku(_ position: GomokuPosition) -> GridGameRecommendation? {
        guard let point = GomokuHeuristicEngine.bestMove(in: position) else { return nil }
        return GridGameRecommendation(
            coordinate: point,
            notation: coordinateName(point),
            score: 80,
            reason: "本地连五战术与阻挡校验"
        )
    }

    static func go(_ position: GoPosition) -> GridGameRecommendation {
        switch GoHeuristicEngine.bestMove(in: position) {
        case let .play(point):
            return GridGameRecommendation(
                coordinate: point,
                notation: coordinateName(point),
                score: 65,
                reason: "本地提子优先与中心控场"
            )
        case .pass:
            return GridGameRecommendation(coordinate: nil, notation: "停一手", score: 50, reason: "局面无安全落点")
        }
    }

    private static func coordinateName(_ point: GridCoordinate) -> String {
        let letters = Array("ABCDEFGHJKLMNOPQRST")
        let file = point.column < letters.count ? String(letters[point.column]) : "?"
        return "\(file)\(point.row + 1)"
    }
}
