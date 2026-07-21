import ApplicationServices
import Foundation
import Vision
import XiangqiCore

enum XiangqiWizardTerminalResult: Equatable, Sendable {
    case win
    case loss
    case draw

    var title: String {
        switch self {
        case .win: "获胜"
        case .loss: "落败"
        case .draw: "和棋"
        }
    }
}

/// Deterministic adapter for 象棋巫师's visible move list. It is used only as
/// a second source of truth when pixel deltas contain ambiguous last-move
/// decorations. Every string still has to resolve to exactly one legal move
/// in the locally trusted position.
enum XiangqiWizardMoveLogReader {
    static let bundleIdentifier = "com.jpcxc.xqwiphone"

    /// Replays every currently exposed official notation from the standard
    /// position. This is the cold-start path for connecting to a game already
    /// in progress; assuming a fresh opening here makes otherwise-correct
    /// clicks target squares that are now empty.
    static func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])? {
        var notations: [String] = []
        for plyIndex in 0..<512 {
            guard let notation = recordedNotation(ownerPID: ownerPID, plyIndex: plyIndex) else {
                break
            }
            notations.append(notation)
        }
        return replayedPosition(notations: notations)
    }

    static func replayedPosition(notations: [String]) -> (position: Position, moves: [Move])? {
        guard !notations.isEmpty else { return nil }
        var position = Position.standard
        var moves: [Move] = []
        for notation in notations {
            guard let move = uniqueLegalMove(matching: notation, in: position),
                  let next = try? position.applying(move) else {
                return nil
            }
            moves.append(move)
            position = next
        }
        return (position, moves)
    }

    static func latestLegalMove(
        ownerPID: pid_t,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        guard let notation = recordedNotation(ownerPID: ownerPID, plyIndex: expectedPlyIndex) else {
            return nil
        }
        return uniqueLegalMove(matching: notation, in: position)
    }

    static func terminalResult(ownerPID: pid_t) -> XiangqiWizardTerminalResult? {
        let application = AXUIElementCreateApplication(ownerPID)
        var descriptions: [String] = []
        collectTerminalText(from: application, depth: 0, into: &descriptions)
        return terminalResult(in: descriptions)
    }

    static func terminalResult(in descriptions: [String]) -> XiangqiWizardTerminalResult? {
        let joined = descriptions.joined(separator: "\n")
        if joined.contains("电脑认输") || joined.contains("恭喜你取得胜利") {
            return .win
        }
        if joined.contains("你认输") || joined.contains("电脑取得胜利")
            || joined.contains("很遗憾，你输了") {
            return .loss
        }
        if joined.contains("本局和棋") || joined.contains("双方和棋")
            || joined.contains("和棋！") || joined.contains("和棋!") {
            return .draw
        }
        return nil
    }

    /// Reads only the visible move-list panel when the iOS-on-macOS
    /// accessibility bridge virtualizes scrolled rows and stops exposing the
    /// newest one. Vision runs entirely on device.
    static func latestLegalMove(
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        let cropRect = CGRect(
            x: CGFloat(image.width) * 0.675,
            y: CGFloat(image.height) * 0.355,
            width: CGFloat(image.width) * 0.285,
            height: CGFloat(image.height) * 0.365
        ).integral
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        let rows = groupedTextRows(observations)
        return uniqueLegalMove(
            inRecognizedLines: rows,
            expectedPlyIndex: expectedPlyIndex,
            position: position
        )
    }

    static func uniqueLegalMove(matching notation: String, in position: Position) -> Move? {
        let expected = normalize(notation)
        let matches = position.legalMoves.filter {
            normalizedNotation(for: $0, in: position) == expected
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func uniqueLegalMove(
        inRecognizedLines lines: [String],
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        let expectedRound = expectedPlyIndex / 2 + 1
        let wantsRedColumn = expectedPlyIndex.isMultiple(of: 2)
        let columnIndex = wantsRedColumn ? 0 : 1
        var selected = Set<Move>()
        for line in lines {
            guard let notations = recognizedNotationColumns(
                in: line,
                expectedRound: expectedRound
            ), notations.indices.contains(columnIndex),
                  let move = uniqueLegalMove(
                    matching: notations[columnIndex],
                    in: position
                  ) else { continue }
            selected.insert(move)
        }
        guard selected.count == 1 else { return nil }
        return selected.first
    }

    static func normalizedNotation(for move: Move, in position: Position) -> String {
        guard let piece = position.board[move.from] else { return "" }
        let peers = position.board.placements
            .filter {
                $0.piece == piece && $0.square.file == move.from.file
            }
            .sorted { lhs, rhs in
                piece.side == .red
                    ? lhs.square.rank < rhs.square.rank
                    : lhs.square.rank > rhs.square.rank
            }

        let pieceName = normalizedPieceName(piece)
        let prefix: String
        if peers.count <= 1 {
            prefix = pieceName + String(fileNumber(move.from.file, side: piece.side))
        } else if let index = peers.firstIndex(where: { $0.square == move.from }) {
            let qualifier: String
            switch (peers.count, index) {
            case (_, 0): qualifier = "前"
            case (2, 1): qualifier = "后"
            case (3, 1): qualifier = "中"
            case (3, 2): qualifier = "后"
            default: qualifier = String(index + 1)
            }
            prefix = qualifier + pieceName
        } else {
            return ""
        }

        if move.from.rank == move.to.rank {
            return prefix + "平" + String(fileNumber(move.to.file, side: piece.side))
        }

        let advances = piece.side == .red
            ? move.to.rank < move.from.rank
            : move.to.rank > move.from.rank
        let action = advances ? "进" : "退"
        let suffix: Int
        switch piece.kind {
        case .horse, .elephant, .advisor:
            suffix = fileNumber(move.to.file, side: piece.side)
        case .general, .chariot, .cannon, .soldier:
            suffix = abs(move.to.rank - move.from.rank)
        }
        return prefix + action + String(suffix)
    }

    static func normalize(_ notation: String) -> String {
        let replacements: [Character: Character] = [
            "車": "车", "俥": "车", "馬": "马", "傌": "马",
            "砲": "炮", "將": "将", "帥": "帅", "進": "进",
            "後": "后", "１": "1", "２": "2", "３": "3",
            "４": "4", "５": "5", "６": "6", "７": "7",
            "８": "8", "９": "9", "一": "1", "二": "2",
            "三": "3", "四": "4", "五": "5", "六": "6",
            "七": "7", "八": "8", "九": "9"
        ]
        return String(notation.compactMap { character -> Character? in
            if character.isWhitespace || character == "," || character == "，" { return nil }
            return replacements[character] ?? character
        })
    }

    private static func recordedNotation(ownerPID: pid_t, plyIndex: Int) -> String? {
        let application = AXUIElementCreateApplication(ownerPID)
        var descriptions: [String] = []
        collectDescriptions(from: application, depth: 0, into: &descriptions)
        let expectedRound = plyIndex / 2 + 1
        let tokenIndex = plyIndex.isMultiple(of: 2) ? 1 : 2

        for description in descriptions.reversed() {
            let parts = description.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // Before the computer replies, 象棋巫师 exposes a row as just
            // "1., 炮八平五".  Requiring a third (black) column made the
            // reader ignore every freshly played red move and left the
            // cockpit on the previous FEN.
            guard parts.indices.contains(tokenIndex) else { continue }
            let roundToken = parts[0].replacingOccurrences(of: ".", with: "")
            guard Int(normalize(roundToken)) == expectedRound,
                  parts.indices.contains(tokenIndex),
                  !parts[tokenIndex].isEmpty else { continue }
            return parts[tokenIndex]
        }
        return nil
    }

    private static func groupedTextRows(_ observations: [VNRecognizedTextObservation]) -> [String] {
        struct Fragment {
            let x: CGFloat
            let y: CGFloat
            let text: String
        }
        let fragments = observations.compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Fragment(
                x: observation.boundingBox.minX,
                y: observation.boundingBox.midY,
                text: text
            )
        }.sorted {
            if abs($0.y - $1.y) > 0.018 { return $0.y > $1.y }
            return $0.x < $1.x
        }

        var rows: [[Fragment]] = []
        for fragment in fragments {
            if let index = rows.indices.last,
               abs((rows[index].map(\.y).reduce(0, +) / CGFloat(rows[index].count)) - fragment.y) <= 0.025 {
                rows[index].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }
    }

    /// A newly appended 象棋巫师 row is rendered in two transactions:
    /// first the round number and red notation, then the black notation. Never
    /// search the entire row for a legal move because a legal black reply can
    /// have the same four-character notation as the already-played red move.
    /// Each official notation emitted by this app is exactly four normalized
    /// characters (piece/qualifier, file/piece, action, file/distance).
    private static func recognizedNotationColumns(
        in rawLine: String,
        expectedRound: Int
    ) -> [String]? {
        let line = normalize(rawLine)
        let prefixes = ["\(expectedRound).", "\(expectedRound)、", "\(expectedRound):"]
        guard let match = prefixes.compactMap({ line.range(of: $0) }).first else {
            return nil
        }
        let payload = line[match.upperBound...]
        let characters = Array(payload)
        guard characters.count >= 4 else { return nil }
        var columns: [String] = []
        var offset = 0
        while offset + 4 <= characters.count, columns.count < 2 {
            columns.append(String(characters[offset..<(offset + 4)]))
            offset += 4
        }
        return columns
    }

    private static func collectDescriptions(
        from element: AXUIElement,
        depth: Int,
        into descriptions: inout [String]
    ) {
        guard depth <= 9 else { return }
        var rawDescription: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXDescriptionAttribute as CFString,
            &rawDescription
        ) == .success,
           let description = rawDescription as? String,
           !description.isEmpty {
            descriptions.append(description)
        }

        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &rawChildren
        ) == .success,
              let children = rawChildren as? [AXUIElement] else { return }
        for child in children {
            collectDescriptions(from: child, depth: depth + 1, into: &descriptions)
        }
    }

    private static func collectTerminalText(
        from element: AXUIElement,
        depth: Int,
        into descriptions: inout [String]
    ) {
        guard depth <= 12 else { return }
        for attribute in [
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXTitleAttribute as String
        ] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
               let text = raw as? String,
               !text.isEmpty {
                descriptions.append(text)
            }
        }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &rawChildren
        ) == .success,
              let children = rawChildren as? [AXUIElement] else { return }
        for child in children {
            collectTerminalText(from: child, depth: depth + 1, into: &descriptions)
        }
    }

    private static func fileNumber(_ file: Int, side: Side) -> Int {
        side == .red ? 9 - file : file + 1
    }

    private static func normalizedPieceName(_ piece: Piece) -> String {
        switch (piece.side, piece.kind) {
        case (.red, .general): return "帅"
        case (.black, .general): return "将"
        case (.red, .advisor): return "仕"
        case (.black, .advisor): return "士"
        case (.red, .elephant): return "相"
        case (.black, .elephant): return "象"
        case (_, .horse): return "马"
        case (_, .chariot): return "车"
        case (_, .cannon): return "炮"
        case (.red, .soldier): return "兵"
        case (.black, .soldier): return "卒"
        }
    }
}
