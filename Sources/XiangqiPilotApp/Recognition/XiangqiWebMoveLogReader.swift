import ApplicationServices
import Foundation
import XiangqiCore

/// Deterministic adapter for the move list rendered by Xah Lee's web-based
/// Chinese Chess board. The page exposes ICCS coordinates through macOS
/// accessibility, so the cockpit can synchronize a browser game from its
/// official move history rather than trying to OCR stylized pieces.
///
/// ICCS uses `a0` at Red's lower-left corner, which is exactly the UCCI
/// coordinate system used by `XiangqiCore`.
enum XiangqiWebMoveLogReader {
    static let xahLeeTitle = "Play Chinese Chess Online"

    static func matches(bundleIdentifier: String?, windowTitle: String) -> Bool {
        guard bundleIdentifier == "com.google.Chrome"
                || bundleIdentifier == "com.apple.Safari"
                || bundleIdentifier == "com.microsoft.edgemac" else {
            return false
        }
        return windowTitle.localizedCaseInsensitiveContains(xahLeeTitle)
    }

    static func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])? {
        let strings = collectedText(ownerPID: ownerPID)
        // An untouched page has only the explicit `=== Start ===` entry; an
        // unavailable AX subtree has neither that marker nor a coordinate.
        // Never turn an inaccessible browser page into a fabricated standard
        // position.
        guard strings.contains(where: { $0.contains("=== Start ===") }) else {
            return nil
        }
        let notations = recordedNotations(from: strings)
        let moves = notations.compactMap(move(fromICCS:))
        guard moves.count == notations.count else { return nil }
        var position = Position.standard
        for move in moves {
            guard let next = try? position.applying(move) else { return nil }
            position = next
        }
        return (position, moves)
    }

    static func latestLegalMove(
        ownerPID: pid_t,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        let moves = recordedMoves(ownerPID: ownerPID)
        guard moves.indices.contains(expectedPlyIndex) else { return nil }
        let move = moves[expectedPlyIndex]
        return position.legalMoves.contains(move) ? move : nil
    }

    static func recordedMoves(ownerPID: pid_t) -> [Move] {
        recordedNotations(ownerPID: ownerPID).compactMap(move(fromICCS:))
    }

    static func recordedNotations(ownerPID: pid_t) -> [String] {
        recordedNotations(from: collectedText(ownerPID: ownerPID))
    }

    /// Chrome has two AX representations for the move list.  Some releases
    /// expose one complete text value; others expose one descendant per move.
    /// The previous implementation selected the richest *single* value, which
    /// silently reduced a long game to whichever individual row happened to be
    /// first.  Prefer a complete value when present; otherwise preserve the
    /// DOM-order sequence of one-move descendants.
    static func recordedNotations(from strings: [String]) -> [String] {
        let candidates = strings.map(iccsNotations(in:)).filter { !$0.isEmpty }

        if let richest = candidates.max(by: { $0.count < $1.count }), richest.count > 1 {
            return richest
        }
        // One-row-per-descendant representation.  `collectedText` walks the
        // AX tree in display order, so this is the authoritative move order.
        return candidates.flatMap { $0 }
    }

    private static func collectedText(ownerPID: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(ownerPID)
        var strings: [String] = []
        collectText(from: application, depth: 0, into: &strings)
        return strings
    }

    static func move(fromICCS notation: String) -> Move? {
        let compact = notation.uppercased().replacingOccurrences(of: "-", with: "")
        guard compact.count == 4 else { return nil }
        return Move(ucci: compact.lowercased())
    }

    static func iccsNotations(in raw: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: "[A-Ia-i][0-9]\\s*-\\s*[A-Ia-i][0-9]")
        let range = NSRange(raw.startIndex..., in: raw)
        let values = expression?.matches(in: raw, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: raw) else { return nil }
            return raw[range]
                .uppercased()
                .replacingOccurrences(of: " ", with: "")
        } ?? []
        return values
    }

    private static func collectText(
        from element: AXUIElement,
        depth: Int,
        into strings: inout [String]
    ) {
        // Chromium exposes a fairly deep DOM-to-AX tree. The game list lives
        // beyond depth 14 on current Chrome builds.
        guard depth <= 40 else { return }
        for attribute in [
            kAXValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXTitleAttribute as String
        ] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
               let text = raw as? String,
               !text.isEmpty {
                strings.append(text)
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
            collectText(from: child, depth: depth + 1, into: &strings)
        }
    }
}
