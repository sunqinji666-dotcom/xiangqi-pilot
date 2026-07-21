import CoreGraphics
import Foundation
import XiangqiCore

/// A single target client is responsible for declaring what it can prove.
/// Runtime code must not grow another bundle-ID conditional every time a new
/// chess client is supported.  In particular, an adapter may offer an
/// authoritative move log, but it never supplies an unchecked board state:
/// every returned move is resolved against `XiangqiCore`'s current legal list.
protocol XiangqiClientAdapter {
    var identifier: String { get }
    var moveLogIsAuthoritative: Bool { get }
    var permitsBackgroundObservation: Bool { get }
    var orientationPreset: BoardOrientation? { get }

    func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])?
    func latestLegalMove(
        ownerPID: pid_t,
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move?
    func terminalResult(ownerPID: pid_t) -> XiangqiWizardTerminalResult?
}

extension XiangqiClientAdapter {
    func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])? { nil }
    func terminalResult(ownerPID: pid_t) -> XiangqiWizardTerminalResult? { nil }
}

private struct VisualOnlyXiangqiAdapter: XiangqiClientAdapter {
    let identifier = "visual-only"
    let moveLogIsAuthoritative = false
    let permitsBackgroundObservation = false
    let orientationPreset: BoardOrientation? = nil

    func latestLegalMove(
        ownerPID: pid_t,
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? { nil }
}

private struct KuanliXiangqiAdapter: XiangqiClientAdapter {
    let identifier = "kuanli"
    let moveLogIsAuthoritative = false
    let permitsBackgroundObservation = true
    let orientationPreset: BoardOrientation? = .redAtTop

    func latestLegalMove(
        ownerPID: pid_t,
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? { nil }
}

private struct XiangqiWizardClientAdapter: XiangqiClientAdapter {
    let identifier = "xiangqi-wizard"
    let moveLogIsAuthoritative = true
    let permitsBackgroundObservation = false
    let orientationPreset: BoardOrientation? = nil

    func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])? {
        XiangqiWizardMoveLogReader.replayedPosition(ownerPID: ownerPID)
    }

    func latestLegalMove(
        ownerPID: pid_t,
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        XiangqiWizardMoveLogReader.latestLegalMove(
            ownerPID: ownerPID,
            expectedPlyIndex: expectedPlyIndex,
            position: position
        ) ?? XiangqiWizardMoveLogReader.latestLegalMove(
            image: image,
            expectedPlyIndex: expectedPlyIndex,
            position: position
        )
    }

    func terminalResult(ownerPID: pid_t) -> XiangqiWizardTerminalResult? {
        XiangqiWizardMoveLogReader.terminalResult(ownerPID: ownerPID)
    }
}

private struct XahLeeXiangqiWebAdapter: XiangqiClientAdapter {
    let identifier = "xahlee-web"
    let moveLogIsAuthoritative = true
    let permitsBackgroundObservation = true
    let orientationPreset: BoardOrientation? = nil

    func replayedPosition(ownerPID: pid_t) -> (position: Position, moves: [Move])? {
        XiangqiWebMoveLogReader.replayedPosition(ownerPID: ownerPID)
    }

    func latestLegalMove(
        ownerPID: pid_t,
        image: CGImage,
        expectedPlyIndex: Int,
        position: Position
    ) -> Move? {
        XiangqiWebMoveLogReader.latestLegalMove(
            ownerPID: ownerPID,
            expectedPlyIndex: expectedPlyIndex,
            position: position
        )
    }
}

enum XiangqiClientAdapters {
    static var visualOnly: any XiangqiClientAdapter { VisualOnlyXiangqiAdapter() }

    static func resolve(target: LockedCaptureTarget) -> any XiangqiClientAdapter {
        if target.bundleIdentifier == XiangqiWizardMoveLogReader.bundleIdentifier {
            return XiangqiWizardClientAdapter()
        }
        if XiangqiWebMoveLogReader.matches(
            bundleIdentifier: target.bundleIdentifier,
            windowTitle: target.title
        ) {
            return XahLeeXiangqiWebAdapter()
        }
        if target.bundleIdentifier == "com.cronlygames.chschess.mac" {
            return KuanliXiangqiAdapter()
        }
        return VisualOnlyXiangqiAdapter()
    }
}
