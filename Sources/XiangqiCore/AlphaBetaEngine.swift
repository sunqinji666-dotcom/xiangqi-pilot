import Dispatch
import Foundation

public enum ThinkingLevel: String, CaseIterable, Codable, Sendable {
    case instant
    case casual
    case standard
    case strong

    public var limits: SearchLimits {
        switch self {
        case .instant:
            return SearchLimits(maxDepth: 1, timeLimitMilliseconds: 80, maxNodes: 8_000)
        case .casual:
            return SearchLimits(maxDepth: 2, timeLimitMilliseconds: 300, maxNodes: 50_000)
        case .standard:
            return SearchLimits(maxDepth: 3, timeLimitMilliseconds: 1_200, maxNodes: 250_000)
        case .strong:
            return SearchLimits(maxDepth: 5, timeLimitMilliseconds: 4_000, maxNodes: 1_500_000)
        }
    }
}

public struct SearchLimits: Equatable, Sendable {
    public let maxDepth: Int
    public let timeLimitMilliseconds: Int
    public let maxNodes: Int

    public init(maxDepth: Int, timeLimitMilliseconds: Int, maxNodes: Int) {
        precondition(maxDepth >= 1)
        precondition(timeLimitMilliseconds >= 1)
        precondition(maxNodes >= 1)
        self.maxDepth = maxDepth
        self.timeLimitMilliseconds = timeLimitMilliseconds
        self.maxNodes = maxNodes
    }
}

public final class SearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct SearchCandidate: Equatable, Sendable {
    public let move: Move
    /// Score is centipawn-like and is always from the root side's perspective.
    public let score: Int
    public let principalVariation: [Move]

    public init(move: Move, score: Int, principalVariation: [Move]) {
        self.move = move
        self.score = score
        self.principalVariation = principalVariation
    }
}

public struct EngineAnalysis: Equatable, Sendable {
    public let positionKey: PositionKey
    public let side: Side
    public let candidates: [SearchCandidate]
    public let searchedDepth: Int
    public let nodes: Int
    public let elapsedMilliseconds: Int
    public let stoppedByLimit: Bool
    public let terminalStatus: PositionStatus?

    public var bestMove: Move? { candidates.first?.move }

    public init(
        positionKey: PositionKey,
        side: Side,
        candidates: [SearchCandidate],
        searchedDepth: Int,
        nodes: Int,
        elapsedMilliseconds: Int,
        stoppedByLimit: Bool,
        terminalStatus: PositionStatus?
    ) {
        self.positionKey = positionKey
        self.side = side
        self.candidates = candidates
        self.searchedDepth = searchedDepth
        self.nodes = nodes
        self.elapsedMilliseconds = elapsedMilliseconds
        self.stoppedByLimit = stoppedByLimit
        self.terminalStatus = terminalStatus
    }
}

/// A deliberately small, deterministic engine suitable for UI suggestions and
/// as a fallback when no external UCCI engine is running.
public final class AlphaBetaEngine: @unchecked Sendable {
    public static let mateScore = 1_000_000

    public init() {}

    /// Cancel the calling Task or the supplied token. Search checks both at
    /// every node and throws `CancellationError` promptly.
    public func analyze(
        position: Position,
        level: ThinkingLevel = .standard,
        maxCandidates: Int = 5,
        cancellationToken: SearchCancellationToken? = nil
    ) async throws -> EngineAnalysis {
        try analyzeSynchronously(
            position: position,
            limits: level.limits,
            maxCandidates: maxCandidates,
            cancellationToken: cancellationToken
        )
    }

    public func analyzeSynchronously(
        position: Position,
        limits: SearchLimits,
        maxCandidates: Int = 5,
        cancellationToken: SearchCancellationToken? = nil
    ) throws -> EngineAnalysis {
        precondition(maxCandidates >= 1)
        let start = DispatchTime.now().uptimeNanoseconds
        var context = SearchContext(
            deadline: start + UInt64(limits.timeLimitMilliseconds) * 1_000_000,
            maxNodes: limits.maxNodes,
            cancellationToken: cancellationToken
        )
        try context.checkCancellation()

        let initialStatus = position.status
        switch initialStatus {
        case .checkmate, .stalemate, .generalCaptured:
            return EngineAnalysis(
                positionKey: position.key,
                side: position.sideToMove,
                candidates: [],
                searchedDepth: 0,
                nodes: 0,
                elapsedMilliseconds: elapsedMilliseconds(since: start),
                stoppedByLimit: false,
                terminalStatus: initialStatus
            )
        case .ongoing, .check:
            break
        }

        let rootMoves = orderedMoves(position.legalMoves, on: position.board)
        var completedCandidates: [SearchCandidate] = []
        var completedDepth = 0
        var stoppedByLimit = false

        for depth in 1...limits.maxDepth {
            do {
                var iteration: [SearchCandidate] = []
                iteration.reserveCapacity(rootMoves.count)
                var alpha = -Self.mateScore
                let beta = Self.mateScore

                for move in rootMoves {
                    try context.visitNode()
                    let child = position.applyingKnownLegal(move)
                    let line = try negamax(
                        child,
                        depth: depth - 1,
                        ply: 1,
                        alpha: -beta,
                        beta: -alpha,
                        context: &context
                    )
                    let score = -line.score
                    iteration.append(
                        SearchCandidate(
                            move: move,
                            score: score,
                            principalVariation: [move] + line.moves
                        )
                    )
                    alpha = max(alpha, score)
                }

                iteration.sort(by: Self.candidateOrdering)
                completedCandidates = iteration
                completedDepth = depth
            } catch SearchStop.limitReached {
                stoppedByLimit = true
                break
            }
        }

        if completedCandidates.isEmpty {
            // A very small time budget can expire before depth one. Still
            // return legal, statically scored candidates rather than no move.
            completedCandidates = rootMoves.map { move in
                let child = position.applyingKnownLegal(move)
                return SearchCandidate(
                    move: move,
                    score: -evaluate(child.board, for: child.sideToMove),
                    principalVariation: [move]
                )
            }
            completedCandidates.sort(by: Self.candidateOrdering)
        }

        return EngineAnalysis(
            positionKey: position.key,
            side: position.sideToMove,
            candidates: Array(completedCandidates.prefix(maxCandidates)),
            searchedDepth: completedDepth,
            nodes: context.nodes,
            elapsedMilliseconds: elapsedMilliseconds(since: start),
            stoppedByLimit: stoppedByLimit,
            terminalStatus: nil
        )
    }

    private func negamax(
        _ position: Position,
        depth: Int,
        ply: Int,
        alpha initialAlpha: Int,
        beta: Int,
        context: inout SearchContext
    ) throws -> SearchLine {
        try context.visitNode()

        guard position.board.generalSquare(for: position.sideToMove) != nil else {
            return SearchLine(score: -Self.mateScore + ply, moves: [])
        }
        guard position.board.generalSquare(for: position.sideToMove.opponent) != nil else {
            return SearchLine(score: Self.mateScore - ply, moves: [])
        }

        let moves = orderedMoves(position.legalMoves, on: position.board)
        if moves.isEmpty {
            // Checkmate and Xiangqi stalemate are both losses for side to move.
            return SearchLine(score: -Self.mateScore + ply, moves: [])
        }
        if depth == 0 {
            return SearchLine(score: evaluate(position.board, for: position.sideToMove), moves: [])
        }

        var alpha = initialAlpha
        var bestScore = -Self.mateScore
        var bestMoves: [Move] = []
        for move in moves {
            let child = position.applyingKnownLegal(move)
            let childLine = try negamax(
                child,
                depth: depth - 1,
                ply: ply + 1,
                alpha: -beta,
                beta: -alpha,
                context: &context
            )
            let score = -childLine.score
            if score > bestScore {
                bestScore = score
                bestMoves = [move] + childLine.moves
            }
            alpha = max(alpha, score)
            if alpha >= beta { break }
        }
        return SearchLine(score: bestScore, moves: bestMoves)
    }

    private func evaluate(_ board: Board, for side: Side) -> Int {
        var score = 0
        for placement in board.placements {
            var value = placement.piece.kind.materialValue
            if placement.piece.kind == .soldier {
                let crossed = placement.piece.side == .red
                    ? placement.square.rank <= 4
                    : placement.square.rank >= 5
                if crossed { value += 50 }
            }
            score += placement.piece.side == side ? value : -value
        }

        // A small mobility term makes equal-material suggestions less arbitrary.
        score += board.pseudoLegalMoves(for: side).count * 2
        score -= board.pseudoLegalMoves(for: side.opponent).count * 2
        return score
    }

    private func orderedMoves(_ moves: [Move], on board: Board) -> [Move] {
        moves.sorted { lhs, rhs in
            moveOrderingScore(lhs, on: board) > moveOrderingScore(rhs, on: board)
        }
    }

    private func moveOrderingScore(_ move: Move, on board: Board) -> Int {
        guard let captured = board[move.to] else { return 0 }
        let attacker = board[move.from]?.kind.materialValue ?? 0
        return captured.kind.materialValue * 10 - attacker
    }

    private static func candidateOrdering(_ lhs: SearchCandidate, _ rhs: SearchCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.move.ucci < rhs.move.ucci
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Int(elapsed / 1_000_000)
    }
}

private struct SearchLine {
    let score: Int
    let moves: [Move]
}

private enum SearchStop: Error {
    case limitReached
}

private struct SearchContext {
    let deadline: UInt64
    let maxNodes: Int
    let cancellationToken: SearchCancellationToken?
    var nodes = 0

    mutating func visitNode() throws {
        try checkCancellation()
        guard nodes < maxNodes,
              DispatchTime.now().uptimeNanoseconds < deadline else {
            throw SearchStop.limitReached
        }
        nodes += 1
    }

    func checkCancellation() throws {
        if Task.isCancelled || cancellationToken?.isCancelled == true {
            throw CancellationError()
        }
    }
}
