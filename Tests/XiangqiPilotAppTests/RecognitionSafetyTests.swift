import Testing
import CoreGraphics
import Foundation
import XiangqiCore
@testable import XiangqiPilotApp

@Suite struct RecognitionSafetyTests {
    @Test func incompleteClassificationAlwaysRequiresHumanReview() {
        let occupied: Set<BoardCellCoordinate> = [
            BoardCellCoordinate(file: 4, rank: 0),
            BoardCellCoordinate(file: 4, rank: 9)
        ]
        let snapshot = XiangqiRecognitionSnapshot(
            frameSequence: 1,
            pieces: [
                RecognizedPiece(file: 4, rank: 0, side: .black, kind: .general, confidence: 1, glyph: "将")
            ],
            occupiedCells: occupied,
            confidence: 1,
            warnings: []
        )

        #expect(snapshot.requiresHumanReview)
        #expect(!snapshot.hasCompleteClassification)
    }

    @Test func unknownSideAlwaysRequiresHumanReview() {
        let snapshot = XiangqiRecognitionSnapshot(
            frameSequence: 1,
            pieces: [
                RecognizedPiece(file: 4, rank: 0, side: .black, kind: .general, confidence: 1, glyph: "将"),
                RecognizedPiece(file: 4, rank: 9, side: .red, kind: .general, confidence: 1, glyph: "帅"),
                RecognizedPiece(file: 0, rank: 3, side: .unknown, kind: .soldier, confidence: 1, glyph: "卒")
            ],
            confidence: 1,
            warnings: []
        )

        #expect(snapshot.requiresHumanReview)
    }

    @Test func standardOpeningBootstrapUsesOccupancyNotGlyphClassification() {
        let bottom = Set(Position.standard.board.placements.map {
            BoardCellCoordinate(file: $0.square.file, rank: $0.square.rank)
        })
        let top = Set(Position.standard.board.placements.map {
            BoardCellCoordinate(file: 8 - $0.square.file, rank: 9 - $0.square.rank)
        })

        #expect(StandardPositionRecognitionPolicy.matches(
            occupiedCells: bottom,
            orientation: .redAtBottom
        ))
        #expect(StandardPositionRecognitionPolicy.matches(
            occupiedCells: top,
            orientation: .redAtTop
        ))
        #expect(!StandardPositionRecognitionPolicy.matches(
            occupiedCells: bottom.subtracting([BoardCellCoordinate(file: 0, rank: 0)])
                .union([BoardCellCoordinate(file: 0, rank: 1)]),
            orientation: .redAtBottom
        ))
    }

    @Test func clientAdaptersKeepRecordAndVisualCapabilitiesSeparate() {
        let wizard = XiangqiClientAdapters.resolve(target: LockedCaptureTarget(
            windowID: 1,
            ownerPID: 42,
            bundleIdentifier: "com.jpcxc.xqwiphone",
            applicationName: "象棋巫师",
            title: "棋局",
            frameAtLock: .zero
        ))
        #expect(wizard.identifier == "xiangqi-wizard")
        #expect(wizard.moveLogIsAuthoritative)
        #expect(!wizard.permitsBackgroundObservation)

        let kuanli = XiangqiClientAdapters.resolve(target: LockedCaptureTarget(
            windowID: 2,
            ownerPID: 43,
            bundleIdentifier: "com.cronlygames.chschess.mac",
            applicationName: "宽立象棋",
            title: "对局",
            frameAtLock: .zero
        ))
        #expect(!kuanli.moveLogIsAuthoritative)
        #expect(kuanli.permitsBackgroundObservation)
        #expect(kuanli.orientationPreset == .redAtTop)
    }

    @Test func tenPlyStandardGameTracksOnlyStrictLegalEndpointPairs() throws {
        var position = Position.standard
        for ply in 0..<10 {
            let move = try #require(position.legalMoves.sorted { $0.ucci < $1.ucci }.first)
            let change = BoardVisualChange(
                fromFrameSequence: UInt64(ply),
                toFrameSequence: UInt64(ply + 1),
                cells: [
                    (BoardCellCoordinate(file: move.from.file, rank: move.from.rank), 0.90),
                    (BoardCellCoordinate(file: move.to.file, rank: move.to.rank), 0.92)
                ]
            )
            #expect(RecognitionTransitionPolicy.decide(
                trusted: position,
                orientation: .redAtBottom,
                visualChange: change
            ) == .legalMove(move))
            let next = try position.applying(move)
            try XiangqiPieceInventoryPolicy.validateTransition(
                before: position,
                move: move,
                after: next
            )
            position = next
        }
        #expect(position.fullmoveNumber == 6)
    }

    @Test func extraHighlightCanNeverAuthorizeAnObservedMove() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let decorated = BoardVisualChange(
            fromFrameSequence: 1,
            toFrameSequence: 2,
            cells: [
                (BoardCellCoordinate(file: move.from.file, rank: move.from.rank), 0.80),
                (BoardCellCoordinate(file: move.to.file, rank: move.to.rank), 0.82),
                (BoardCellCoordinate(file: 4, rank: 4), 0.15)
            ]
        )
        #expect(RecognitionTransitionPolicy.decide(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: decorated
        ) == .rejected)
    }

    @Test func connectionSessionPublishesOnlyConfirmedRuleEvents() async throws {
        let session = BoardConnectionSession()
        await session.connect(windowID: 101)
        await session.beginCalibration()
        await session.beginInitialSynchronization()
        await session.recordFrame(sequence: 1, presentationTime: 10)
        await session.recordFrame(sequence: 2, presentationTime: 10.05)
        await session.acceptInitialPosition(.standard, confidence: 1, frameSequence: 2)
        await session.observeChange(detail: "检测到两个交点变化")
        await session.beginMoveConfirmation()

        let move = try #require(Move(ucci: "a3a4"))
        let next = try Position.standard.applying(move)
        await session.acceptMove(BoardPositionEvent(
            fen: next.fen,
            moveUCCI: move.ucci,
            sideToMove: next.sideToMove,
            confidence: 1,
            frameSequence: 4
        ))
        let snapshot = await session.snapshot()
        #expect(snapshot.state == .observing)
        #expect(snapshot.latestFEN == next.fen)
        #expect(snapshot.latestMoveUCCI == move.ucci)
        #expect(snapshot.sideToMove == .black)
        #expect((snapshot.framesPerSecond ?? 0) > 15)
    }

    @Test func connectionSessionDistinguishesResyncFromRecalibration() async {
        let session = BoardConnectionSession()
        await session.connect(windowID: 202)
        await session.requireResynchronization("视频跳转")
        var snapshot = await session.snapshot()
        #expect(snapshot.state == .resynchronizationRequired)
        #expect(snapshot.detail == "视频跳转")

        await session.requireRecalibration("窗口尺寸变化")
        snapshot = await session.snapshot()
        #expect(snapshot.state == .recalibrationRequired)
    }

    @Test func manyChangedIntersectionsAreAPositionJumpNotAMove() {
        let change = BoardVisualChange(
            fromFrameSequence: 1,
            toFrameSequence: 2,
            cells: (0..<6).map {
                (BoardCellCoordinate(file: $0, rank: 0), 0.8)
            }
        )
        #expect(BoardContinuityPolicy.assess(change) == .positionJump(changedIntersections: 6))
    }

    @Test func legacyOCRBackendNeverClaimsArbitraryPositionAuthority() {
        let recognizer = XiangqiVisionRecognizer()
        #expect(recognizer.backend == .legacyVisionFallback)
        #expect(!recognizer.backend.canAuthoritativelyClassifyArbitraryPosition)
        #expect(recognizer.backend.displayName.contains("仅作恢复候选"))
    }

    @Test func wizardMoveLogReplaysAnAlreadyStartedGameBeforeClicking() throws {
        let replay = try #require(XiangqiWizardMoveLogReader.replayedPosition(notations: [
            "炮八平五", "炮２平５", "兵七进一", "炮５进４"
        ]))
        #expect(replay.moves.map(\.ucci) == ["b2e2", "b7e7", "c3c4", "e7e3"])
        #expect(replay.position.sideToMove == .red)
        #expect(replay.position.board[Square(file: 2, rank: 5)]?.kind == .soldier)
        #expect(replay.position.board[Square(file: 2, rank: 6)] == nil)
    }

    @Test func hotPathPublishesOnlyAStableNinetyPointChange() async throws {
        let geometry = RecognitionBoardGeometry(
            topLeft: CGPoint(x: 0.10, y: 0.90),
            topRight: CGPoint(x: 0.90, y: 0.90),
            bottomRight: CGPoint(x: 0.90, y: 0.10),
            bottomLeft: CGPoint(x: 0.10, y: 0.10)
        )
        let detector = BoardChangeDetector(requiredStableFrames: 2)
        let baseline = try makeConnectionFrame(changed: [], geometry: geometry)
        let moved = try makeConnectionFrame(
            changed: [
                BoardCellCoordinate(file: 0, rank: 6),
                BoardCellCoordinate(file: 0, rank: 5)
            ],
            geometry: geometry
        )
        _ = detector.ingest(image: baseline, frameSequence: 1, geometry: geometry)
        if case .candidate(_, let count) = detector.ingest(
            image: moved,
            frameSequence: 2,
            geometry: geometry
        ) {
            #expect(count == 1)
        } else {
            #expect(Bool(false), "first changed frame must remain a candidate")
        }
        if case let .stable(change, _) = detector.ingest(
            image: moved,
            frameSequence: 3,
            geometry: geometry
        ) {
            #expect(change.cells.count == 2)
        } else {
            #expect(Bool(false), "second equivalent board frame must be stable")
        }
    }

    @Test func localCollaborationBridgeUsesAPrivateUnixSocket() throws {
        // Darwin's `sockaddr_un.sun_path` is short; use /tmp and a compact
        // random suffix so this test exercises the real bind path.
        let socketPath = "/tmp/xqp-\(UUID().uuidString.prefix(8)).sock"
        let bridge = AICollaborationBridge(socketPath: socketPath)
        defer { bridge.stop() }

        try bridge.start()
        let listening = bridge.snapshot()
        #expect(listening.state == .listening)
        #expect(listening.connectedClients == 0)
        #expect(FileManager.default.fileExists(atPath: socketPath))

        bridge.stop()
        #expect(bridge.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }
}

private func makeConnectionFrame(
    changed: [BoardCellCoordinate],
    geometry: RecognitionBoardGeometry
) throws -> CGImage {
    let size = 240
    let context = try #require(CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.92, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
    for coordinate in changed {
        let point = geometry.intersectionPoint(file: coordinate.file, rank: coordinate.rank)
        let center = CGPoint(x: point.x * CGFloat(size), y: (1 - point.y) * CGFloat(size))
        context.fill(CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
    }
    return try #require(context.makeImage())
}
