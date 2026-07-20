import CoreGraphics
import Foundation
import Testing
import XiangqiCore
@testable import XiangqiPilotApp

@Suite struct CalibrationAndSafetyTests {
    @Test func kuanliBoardOrientationPresetUsesRedAtTop() {
        #expect(BoardOrientation.preset(for: "com.cronlygames.chschess.mac") == .redAtTop)
        #expect(BoardOrientation.preset(for: "com.jpcxc.xqwiphone") == nil)
    }

    @Test func calibrationMapsEveryBoardCornerIntoTheLockedWindow() throws {
        let calibration = try BoardCalibration(
            corners: BoardCorners(
                topLeft: CGPoint(x: 100, y: 80),
                topRight: CGPoint(x: 900, y: 80),
                bottomLeft: CGPoint(x: 100, y: 980),
                bottomRight: CGPoint(x: 900, y: 980)
            ),
            imageSize: CGSize(width: 1_000, height: 1_100),
            windowFrame: CGRect(x: 50, y: 30, width: 500, height: 550)
        )

        let topLeft = try calibration.globalScreenPoint(for: XiangqiGridPoint(file: 0, rank: 0))
        let bottomRight = try calibration.globalScreenPoint(for: XiangqiGridPoint(file: 8, rank: 9))
        #expect(abs(topLeft.x - 100) < 0.001)
        #expect(abs(topLeft.y - 70) < 0.001)
        #expect(abs(bottomRight.x - 500) < 0.001)
        #expect(abs(bottomRight.y - 520) < 0.001)
    }

    @Test func geometryHashIgnoresPureWindowMoveButChangesOnResize() throws {
        let corners = BoardCorners(
            topLeft: CGPoint(x: 10, y: 10),
            topRight: CGPoint(x: 810, y: 10),
            bottomLeft: CGPoint(x: 10, y: 910),
            bottomRight: CGPoint(x: 810, y: 910)
        )
        let first = try BoardCalibration(
            corners: corners,
            imageSize: CGSize(width: 820, height: 920),
            windowFrame: CGRect(x: 0, y: 0, width: 820, height: 920)
        )
        let moved = try first.recalibrated(
            imageSize: first.imageSize,
            windowFrame: CGRect(x: 300, y: 200, width: 820, height: 920)
        )
        #expect(first.geometryHash == moved.geometryHash)

        let resized = try first.recalibrated(
            imageSize: CGSize(width: 900, height: 1_000),
            windowFrame: CGRect(x: 300, y: 200, width: 900, height: 1_000)
        )
        #expect(first.geometryHash != resized.geometryHash)
    }

    @Test func liveWindowTranslationMovesClickPointsWithoutRecalibration() throws {
        let calibration = try BoardCalibration(
            corners: BoardCorners(
                topLeft: CGPoint(x: 100, y: 80),
                topRight: CGPoint(x: 900, y: 80),
                bottomLeft: CGPoint(x: 100, y: 980),
                bottomRight: CGPoint(x: 900, y: 980)
            ),
            imageSize: CGSize(width: 1_000, height: 1_100),
            windowFrame: CGRect(x: 50, y: 30, width: 500, height: 550)
        )
        let movedFrame = CGRect(x: 350, y: 230, width: 500, height: 550)
        let point = try calibration.globalScreenPoint(
            for: XiangqiGridPoint(file: 0, rank: 0),
            in: movedFrame
        )
        #expect(abs(point.x - 400) < 0.001)
        #expect(abs(point.y - 270) < 0.001)
    }

    @Test func recognitionGeometryFindsPerspectiveIntersections() {
        let geometry = RecognitionBoardGeometry(
            topLeft: CGPoint(x: 0.20, y: 0.90),
            topRight: CGPoint(x: 0.80, y: 0.86),
            bottomRight: CGPoint(x: 0.86, y: 0.10),
            bottomLeft: CGPoint(x: 0.14, y: 0.14)
        )
        let expected = geometry.intersectionPoint(file: 6, rank: 7)
        let nearest = geometry.nearestIntersection(to: expected)
        #expect(nearest?.file == 6)
        #expect(nearest?.rank == 7)
        #expect((nearest?.distance ?? 1) < 0.0001)
    }

    @Test func recognitionRegionPadsOuterPiecesAndMapsVisionROICoordinates() {
        let geometry = RecognitionBoardGeometry(
            topLeft: CGPoint(x: 0.10, y: 0.85),
            topRight: CGPoint(x: 0.70, y: 0.85),
            bottomRight: CGPoint(x: 0.70, y: 0.10),
            bottomLeft: CGPoint(x: 0.10, y: 0.10)
        )
        let region = geometry.recognitionRegion

        #expect(region.minX < geometry.boundingBox.minX)
        #expect(region.maxX > geometry.boundingBox.maxX)
        #expect(region.minY < geometry.boundingBox.minY)
        #expect(region.maxY > geometry.boundingBox.maxY)

        let imagePoint = geometry.imagePoint(
            fromRegionPoint: CGPoint(x: 0.5, y: 0.5),
            region: region
        )
        #expect(abs(imagePoint.x - region.midX) < 0.0001)
        #expect(abs(imagePoint.y - region.midY) < 0.0001)
    }

    @Test func boardSignatureIgnoresChangesOutsideBoardButDetectsChangedIntersection() throws {
        let geometry = RecognitionBoardGeometry(
            topLeft: CGPoint(x: 0.25, y: 0.25),
            topRight: CGPoint(x: 0.75, y: 0.25),
            bottomRight: CGPoint(x: 0.75, y: 0.75),
            bottomLeft: CGPoint(x: 0.25, y: 0.75)
        )
        let differencer = BoardFrameDifferencer()
        let baseline = differencer.signature(
            image: try makeTestImage(),
            frameSequence: 1,
            geometry: geometry
        )
        let outsideOnly = differencer.signature(
            image: try makeTestImage(changedRects: [CGRect(x: 0, y: 0, width: 20, height: 20)]),
            frameSequence: 2,
            geometry: geometry
        )
        #expect(differencer.changes(
            from: baseline,
            to: outsideOnly,
            minimumScore: 0.035
        ).cells.isEmpty)

        let boardChanged = differencer.signature(
            image: try makeTestImage(changedRects: [CGRect(x: 90, y: 84, width: 20, height: 20)]),
            frameSequence: 3,
            geometry: geometry
        )
        let changedCells = differencer.changes(
            from: baseline,
            to: boardChanged,
            minimumScore: 0.035
        ).cells
        #expect(changedCells.contains { $0.coordinate == BoardCellCoordinate(file: 4, rank: 4) })
    }

    @Test func staleProposedActionCannotBeApproved() async throws {
        let machine = SessionStateMachine()
        try await machine.transition(to: .selectingWindow)
        try await machine.transition(to: .calibrating)
        try await machine.transition(to: .recognizing)
        let trusted = ObservedStateToken(
            processIdentifier: 10,
            windowIdentifier: 20,
            frameSequence: 30,
            windowGeometryHash: "geometry-a",
            positionHash: "position-a"
        )
        await machine.acceptTrustedObservation(trusted)
        try await machine.transition(to: .deciding)
        try await machine.queue(ProposedAction(
            token: trusted,
            move: "h2e2",
            confidence: 0.99,
            source: "test"
        ))

        let changed = ObservedStateToken(
            processIdentifier: 10,
            windowIdentifier: 20,
            frameSequence: 31,
            windowGeometryHash: "geometry-a",
            positionHash: "position-b"
        )
        do {
            _ = try await machine.approvePendingAction(currentToken: changed)
            Issue.record("A stale action must never be approved")
        } catch {
            #expect(error as? SessionStateError == .staleAction)
        }
        #expect(await machine.phase == .paused)
    }

    @Test func modelResponseMustPreserveFrameAndStateBinding() {
        let requestID = UUID()
        let response = IntelligenceResponse(
            requestID: requestID,
            frameSequence: 8,
            stateHash: "abc",
            confidence: 0.93,
            recognizedFEN: nil,
            suggestedMove: "h2e2",
            explanation: "test",
            warnings: []
        )
        #expect(response.isStructurallyValid)
        let invalid = IntelligenceResponse(
            requestID: requestID,
            frameSequence: 8,
            stateHash: "abc",
            confidence: 1.2,
            recognizedFEN: nil,
            suggestedMove: nil,
            explanation: nil,
            warnings: []
        )
        #expect(!invalid.isStructurallyValid)
    }

    @Test func officialAlibabaRatesProduceDeterministicPerCallCost() async throws {
        let service = AlibabaPricingService()
        let usage = ModelTokenUsage(inputTokens: 1_000, outputTokens: 100)
        let flash = try #require(await service.billing(
            modelID: "qwen3.6-flash",
            usage: usage,
            durationMilliseconds: 800
        ))
        let plus = try #require(await service.billing(
            modelID: "qwen3.7-plus",
            usage: usage,
            durationMilliseconds: 1_200
        ))

        #expect(abs(flash.costCNY - 0.00192) < 0.0000001)
        #expect(abs(plus.costCNY - 0.00224) < 0.0000001)
        #expect(flash.inputTokens == 1_000)
        #expect(flash.outputTokens == 100)
    }

    @Test func modelPositionRejectsImpossiblePieceInventory() throws {
        let impossible = "4k4/9/9/9/9/9/P1P1P1P1P/4P4/9/4K4 w - - 0 1"
        #expect(throws: (any Error).self) {
            _ = try ModelRecognizedPositionPolicy.validatedPosition(
                fen: impossible,
                sideToMove: .red
            )
        }
    }

    @Test func modelPositionAcceptsPlacementOnlyFENAndUsesSelectedTurn() throws {
        let position = try ModelRecognizedPositionPolicy.validatedPosition(
            fen: Position.standard.fen.split(separator: " ")[0].description,
            sideToMove: .black
        )
        #expect(position.board == Position.standard.board)
        #expect(position.sideToMove == .black)
    }

    @Test func visualVerificationDoesNotReuseTheSetupTurnsStaleValue() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let expected = try Position.standard.applying(move)
        let observedWithStaleTurn = Position(board: expected.board, sideToMove: .red)

        #expect(expected.sideToMove == .black)
        #expect(PositionVerificationPolicy.matches(
            observed: observedWithStaleTurn,
            expected: expected
        ))
    }

    @Test func partialOCRVerificationRequiresMatchingPiecesGeneralsAndExactEndpoints() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let expected = try Position.standard.applying(move)
        let omitted: Set<Square> = [
            Square(file: 0, rank: 6), Square(file: 2, rank: 6),
            Square(file: 4, rank: 6), Square(file: 6, rank: 6),
            Square(file: 8, rank: 6), Square(file: 7, rank: 7),
            Square(file: 0, rank: 9), Square(file: 8, rank: 9)
        ]
        let pieces = expected.board.placements.compactMap { placement -> RecognizedPiece? in
            guard !omitted.contains(placement.square) else { return nil }
            let side: RecognizedSide = placement.piece.side == .red ? .red : .black
            let kind: RecognizedPieceKind
            switch placement.piece.kind {
            case .general: kind = .general
            case .advisor: kind = .advisor
            case .elephant: kind = .elephant
            case .horse: kind = .horse
            case .chariot: kind = .chariot
            case .cannon: kind = .cannon
            case .soldier: kind = .soldier
            }
            return RecognizedPiece(
                file: placement.square.file,
                rank: placement.square.rank,
                side: side,
                kind: kind,
                confidence: 0.7,
                glyph: ""
            )
        }
        let snapshot = XiangqiRecognitionSnapshot(
            frameSequence: 42,
            pieces: pieces,
            confidence: 0.7,
            warnings: []
        )
        let exactEndpointChange = BoardVisualChange(
            fromFrameSequence: 41,
            toFrameSequence: 42,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.4),
                (BoardCellCoordinate(file: 1, rank: 0), 0.5)
            ]
        )

        #expect(PositionVerificationPolicy.matches(
            snapshot: snapshot,
            expected: expected,
            move: move,
            orientation: .redAtBottom,
            visualChange: exactEndpointChange
        ))

        let unrelatedChange = BoardVisualChange(
            fromFrameSequence: 41,
            toFrameSequence: 42,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.4),
                (BoardCellCoordinate(file: 2, rank: 0), 0.5)
            ]
        )
        #expect(!PositionVerificationPolicy.matches(
            snapshot: snapshot,
            expected: expected,
            move: move,
            orientation: .redAtBottom,
            visualChange: unrelatedChange
        ))

        let withoutRedGeneral = XiangqiRecognitionSnapshot(
            frameSequence: 42,
            pieces: pieces.filter { !($0.side == .red && $0.kind == .general) },
            confidence: 0.7,
            warnings: ["未确认红帅"]
        )
        #expect(!PositionVerificationPolicy.matches(
            snapshot: withoutRedGeneral,
            expected: expected,
            move: move,
            orientation: .redAtBottom,
            visualChange: exactEndpointChange
        ))
    }

    @Test func trustedRecognitionRejectsOCRDriftWithoutChangingTheBoard() throws {
        let trusted = Position.standard
        var placements = trusted.board.placements
        placements.removeAll { $0.square == Square(file: 4, rank: 6) }
        let drifted = Position(board: try Board(placements: placements), sideToMove: .red)

        #expect(RecognitionTransitionPolicy.decide(
            trusted: trusted,
            observed: drifted,
            orientation: .redAtBottom,
            visualChange: BoardVisualChange(
                fromFrameSequence: 1,
                toFrameSequence: 2,
                cells: []
            )
        ) == .rejected)
    }

    @Test func trustedRecognitionAcceptsOnlyOneLegalMoveWithExactVisualEndpoints() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let observed = try Position.standard.applying(move)
        let exactChange = BoardVisualChange(
            fromFrameSequence: 10,
            toFrameSequence: 11,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.5),
                (BoardCellCoordinate(file: 1, rank: 0), 0.6)
            ]
        )

        #expect(RecognitionTransitionPolicy.decide(
            trusted: .standard,
            observed: observed,
            orientation: .redAtBottom,
            visualChange: exactChange
        ) == .legalMove(move))

        let noisyChange = BoardVisualChange(
            fromFrameSequence: 10,
            toFrameSequence: 11,
            cells: exactChange.cells + [(BoardCellCoordinate(file: 4, rank: 4), 0.2)]
        )
        #expect(RecognitionTransitionPolicy.decide(
            trusted: .standard,
            observed: observed,
            orientation: .redAtBottom,
            visualChange: noisyChange
        ) == .rejected)
    }

    @Test func trustedRecognitionCanInferTheMoveFromTwoChangedCellsWithoutOCR() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let exactChange = BoardVisualChange(
            fromFrameSequence: 20,
            toFrameSequence: 21,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.45),
                (BoardCellCoordinate(file: 1, rank: 0), 0.52)
            ]
        )
        #expect(RecognitionTransitionPolicy.decide(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: exactChange
        ) == .legalMove(move))

        let selectedPieceOnly = BoardVisualChange(
            fromFrameSequence: 20,
            toFrameSequence: 21,
            cells: [(BoardCellCoordinate(file: 1, rank: 7), 0.45)]
        )
        #expect(RecognitionTransitionPolicy.decide(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: selectedPieceOnly
        ) == .rejected)
    }

    @Test func decoratedTransitionRequiresBothEndpointsButToleratesAHighlight() throws {
        let move = try #require(Move(ucci: "b2b9"))
        let decorated = BoardVisualChange(
            fromFrameSequence: 30,
            toFrameSequence: 31,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.48),
                (BoardCellCoordinate(file: 1, rank: 0), 0.57),
                // Persistent last-move or selection decoration.
                (BoardCellCoordinate(file: 4, rank: 4), 0.12)
            ]
        )
        #expect(RecognitionTransitionPolicy.decoratedLegalMove(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: decorated
        ) == move)

        let oneEndpointOnly = BoardVisualChange(
            fromFrameSequence: 30,
            toFrameSequence: 31,
            cells: [
                (BoardCellCoordinate(file: 1, rank: 7), 0.48),
                (BoardCellCoordinate(file: 4, rank: 4), 0.12)
            ]
        )
        #expect(RecognitionTransitionPolicy.decoratedLegalMove(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: oneEndpointOnly
        ) == nil)
    }

    @Test func stableFourEndpointDeltaCanSynchronizeTwoConsecutivePlies() throws {
        let first = try #require(Move(ucci: "h2e2"))
        let afterFirst = try Position.standard.applying(first)
        let second = try #require(afterFirst.legalMoves.first)
        let cells = [first.from, first.to, second.from, second.to].map {
            (BoardCellCoordinate(file: $0.file, rank: $0.rank), 0.58)
        }
        let change = BoardVisualChange(
            fromFrameSequence: 40,
            toFrameSequence: 41,
            cells: cells
        )
        #expect(RecognitionTransitionPolicy.decoratedLegalLine(
            trusted: .standard,
            orientation: .redAtBottom,
            visualChange: change
        ) == [first, second])
    }

    @Test func dispatchedCannonMoveCanRecognizeRealWizardHorseReply() throws {
        let first = try #require(Move(ucci: "h2e2"))
        let reply = try #require(Move(ucci: "b9c7"))
        let change = BoardVisualChange(
            fromFrameSequence: 50,
            toFrameSequence: 51,
            cells: [first.from, first.to, reply.from, reply.to].map {
                (BoardCellCoordinate(file: $0.file, rank: $0.rank), 0.60)
            }
        )
        #expect(RecognitionTransitionPolicy.decoratedLegalReply(
            trusted: .standard,
            firstMove: first,
            orientation: .redAtBottom,
            visualChange: change
        ) == reply)
    }

    @Test func wizardNotationResolvesVisibleMoveLogAgainstLegalMoves() throws {
        let first = try #require(
            XiangqiWizardMoveLogReader.uniqueLegalMove(
                matching: "炮二平五",
                in: .standard
            )
        )
        #expect(first.ucci == "h2e2")
        let afterFirst = try Position.standard.applying(first)
        let reply = try #require(
            XiangqiWizardMoveLogReader.uniqueLegalMove(
                matching: "马８进７",
                in: afterFirst
            )
        )
        #expect(reply.ucci == "h9g7")
        #expect(
            XiangqiWizardMoveLogReader.normalizedNotation(for: reply, in: afterFirst)
                == "马8进7"
        )
    }

    @Test func wizardCannonAdvanceNotationResolvesAfterSixOpeningRounds() throws {
        let ucciLine = [
            "h2e2", "h9g7", "h0g2", "i9h9", "i0h0", "b9c7",
            "b0a2", "g6g5", "b2c2", "a9b9", "a0b0"
        ]
        var position = Position.standard
        for ucci in ucciLine {
            let move = try #require(Move(ucci: ucci))
            position = try position.applying(move)
        }
        let reply = try #require(
            XiangqiWizardMoveLogReader.uniqueLegalMove(
                matching: "炮２进４",
                in: position
            )
        )
        #expect(reply.ucci == "b7b3")
    }

    @Test func wizardChariotAdvanceNotationResolvesAfterAlternateOpening() throws {
        let ucciLine = [
            "c3c4", "g6g5", "b0c2", "h9g7", "a0a1", "c9e7",
            "g0e2", "b9d8", "h0f1", "a9c9", "a1d1"
        ]
        var position = Position.standard
        for ucci in ucciLine {
            let move = try #require(Move(ucci: ucci))
            position = try position.applying(move)
        }
        let reply = try #require(
            XiangqiWizardMoveLogReader.uniqueLegalMove(
                matching: "车９进１",
                in: position
            )
        )
        #expect(reply.ucci == "i9i8")
    }

    @Test func wizardOCRLineParserBindsLatestRoundToUniqueLegalMove() throws {
        let first = try #require(Move(ucci: "h2e2"))
        let afterFirst = try Position.standard.applying(first)
        let move = XiangqiWizardMoveLogReader.uniqueLegalMove(
            inRecognizedLines: [
                "12. 车四进三 车4进3",
                "13. 仕四进五 炮8进2"
            ],
            expectedPlyIndex: 25,
            position: afterFirst
        )
        #expect(move?.ucci == "h7h5")

        let reply = XiangqiWizardMoveLogReader.uniqueLegalMove(
            inRecognizedLines: ["1. 炮二平五 马8进7"],
            expectedPlyIndex: 1,
            position: afterFirst
        )
        #expect(reply?.ucci == "h9g7")
    }

    @Test func wizardOCRNeverMatchesTheOtherPlayersIdenticalNotationColumn() throws {
        // Real 象棋巫师 game from 2026-07-20. In round 13 both the
        // red move already played and another legal black move normalize to
        // "马3进4". The black column is "马8进7" and must win; scanning
        // the whole row for any legal notation used to choose c7d5 and drift.
        let played = [
            "h2e2", "h9g7", "g3g4", "c6c5", "h0g2", "b9c7",
            "i0h0", "i9h9", "b0a2", "h7h3", "a0a1", "h3g3",
            "h0h9", "g7h9", "b2c2", "g3g0", "f0e1", "a9b9",
            "c3c4", "g0g1", "c2c1", "g1c1", "a1c1", "b7b2",
            "g2f4"
        ]
        var position = Position.standard
        for ucci in played {
            position = try position.applying(#require(Move(ucci: ucci)))
        }

        let move = XiangqiWizardMoveLogReader.uniqueLegalMove(
            inRecognizedLines: ["13. 马三进四 马8进7"],
            expectedPlyIndex: 25,
            position: position
        )
        #expect(move?.ucci == "h9g7")

        let rowBeforeBlackNotationWasRendered =
            XiangqiWizardMoveLogReader.uniqueLegalMove(
                inRecognizedLines: ["13. 马三进四"],
                expectedPlyIndex: 25,
                position: position
            )
        #expect(rowBeforeBlackNotationWasRendered == nil)
    }

    @Test func wizardTerminalDialogIsRecognizedWithoutMatchingOrdinaryButtons() {
        #expect(XiangqiWizardMoveLogReader.terminalResult(in: [
            "提和", "认输", "电脑认输,恭喜你取得胜利!", "再来一次"
        ]) == .win)
        #expect(XiangqiWizardMoveLogReader.terminalResult(in: [
            "你认输,电脑取得胜利", "再来一次"
        ]) == .loss)
        #expect(XiangqiWizardMoveLogReader.terminalResult(in: [
            "本局和棋", "再来一次"
        ]) == .draw)
        #expect(XiangqiWizardMoveLogReader.terminalResult(in: [
            "提和", "认输", "悔棋"
        ]) == nil)
    }

    @Test func webMoveLogParsesICCSWithoutUsingOCR() throws {
        let text = """
        === Start ===
         1.B2-E2
           B9-C7
         2.I3-I4
           A9-B9
        """
        #expect(XiangqiWebMoveLogReader.iccsNotations(in: text) == [
            "B2-E2", "B9-C7", "I3-I4", "A9-B9"
        ])
        #expect(XiangqiWebMoveLogReader.move(fromICCS: "B2-E2")?.ucci == "b2e2")
        #expect(XiangqiWebMoveLogReader.move(fromICCS: "I3-I4")?.ucci == "i3i4")
    }

    @Test func webMoveLogKeepsEveryChromeOneRowPerMoveEntry() {
        // Chrome's current accessibility tree exposes each list-box row as a
        // distinct value instead of putting the whole score in one value.
        // Do not collapse that representation to its first single move.
        let rows = [
            "=== Start ===",
            " 1.B2-E2", "   B9-C7",
            " 2.I3-I4", "   A9-B9",
            " 3.G3-G4", "   H9-I7"
        ]
        #expect(XiangqiWebMoveLogReader.recordedNotations(from: rows) == [
            "B2-E2", "B9-C7", "I3-I4", "A9-B9", "G3-G4", "H9-I7"
        ])
    }

    @Test func webMoveLogReplaysTheObservedPageOpeningUnderCoreRules() throws {
        let pageMoves = [
            "B2-E2", "B9-C7", "I3-I4", "A9-B9",
            "G3-G4", "H9-I7", "E3-E4", "H7-E7",
            "C3-C4", "I9-H9", "A3-A4", "E7-E4",
            "F0-E1", "H9-H2", "I4-I5", "I6-I5",
            "G4-G5", "H2-H1"
        ]
        var position = Position.standard
        for notation in pageMoves {
            let move = try #require(XiangqiWebMoveLogReader.move(fromICCS: notation))
            position = try position.applying(move)
        }
        #expect(position.sideToMove == .red)
        // The recorded web line contains two captures, including the cannon
        // exchange on the central file.
        #expect(position.board.pieceCount() == 29)
    }

    @Test func webAdapterOnlyClaimsItsKnownBrowserPage() {
        #expect(XiangqiWebMoveLogReader.matches(
            bundleIdentifier: "com.google.Chrome",
            windowTitle: "Play Chinese Chess Online"
        ))
        #expect(!XiangqiWebMoveLogReader.matches(
            bundleIdentifier: "com.google.Chrome",
            windowTitle: "Xiangqi - PlayOK"
        ))
    }

    @Test func standardOpeningCanRecoverFromWrongPieceColoursButRejectsMovedKind() throws {
        let pieces = Position.standard.board.placements.map { placement in
            RecognizedPiece(
                file: placement.square.file,
                rank: placement.square.rank,
                side: placement.piece.side == .red ? .black : .red,
                kind: recognizedKind(placement.piece.kind),
                confidence: 0.45,
                glyph: ""
            )
        }
        let noisyStandard = XiangqiRecognitionSnapshot(
            frameSequence: 1,
            pieces: Array(pieces.dropLast()),
            occupiedCells: Set(pieces.map {
                BoardCellCoordinate(file: $0.file, rank: $0.rank)
            }),
            confidence: 0.42,
            warnings: ["颜色不确定"]
        )
        #expect(StandardPositionRecognitionPolicy.matches(
            snapshot: noisyStandard,
            orientation: .redAtBottom
        ))

        var moved = pieces
        moved.removeAll { $0.file == 1 && $0.rank == 7 }
        moved.removeAll { $0.file == 1 && $0.rank == 0 }
        moved.append(RecognizedPiece(
            file: 1,
            rank: 0,
            side: .red,
            kind: .cannon,
            confidence: 0.9,
            glyph: "炮"
        ))
        let afterCapture = XiangqiRecognitionSnapshot(
            frameSequence: 2,
            pieces: moved,
            confidence: 0.9,
            warnings: []
        )
        #expect(!StandardPositionRecognitionPolicy.matches(
            snapshot: afterCapture,
            orientation: .redAtBottom
        ))

        let movedOccupancy = XiangqiRecognitionSnapshot(
            frameSequence: 3,
            pieces: pieces,
            occupiedCells: Set(pieces.map {
                BoardCellCoordinate(file: $0.file, rank: $0.rank)
            }).subtracting([BoardCellCoordinate(file: 2, rank: 3)])
                .union([BoardCellCoordinate(file: 2, rank: 4)]),
            confidence: 0.99,
            warnings: []
        )
        #expect(!StandardPositionRecognitionPolicy.matches(
            snapshot: movedOccupancy,
            orientation: .redAtBottom
        ))
    }
    @Test func recoveryNeverAutoAppliesOneModelsOpinion() throws {
        let model = PositionRecoverySafetyPolicy.Evidence(
            position: .standard,
            confidence: 0.99
        )
        #expect(!PositionRecoverySafetyPolicy.canAutoApply(local: nil, models: [model]))
    }

    @Test func recoveryAutoApplyRequiresIndependentBoardAgreement() throws {
        let first = PositionRecoverySafetyPolicy.Evidence(position: .standard, confidence: 0.93)
        let second = PositionRecoverySafetyPolicy.Evidence(position: .standard, confidence: 0.91)
        #expect(PositionRecoverySafetyPolicy.canAutoApply(local: nil, models: [first, second]))

        let moved = try Position.standard.applying(Move(ucci: "a3a4")!)
        let disagreement = PositionRecoverySafetyPolicy.Evidence(position: moved, confidence: 0.99)
        #expect(!PositionRecoverySafetyPolicy.canAutoApply(local: nil, models: [first, disagreement]))
    }
}

private func recognizedKind(_ kind: PieceKind) -> RecognizedPieceKind {
    switch kind {
    case .general: .general
    case .advisor: .advisor
    case .elephant: .elephant
    case .horse: .horse
    case .chariot: .chariot
    case .cannon: .cannon
    case .soldier: .soldier
    }
}

private func makeTestImage(changedRects: [CGRect] = []) throws -> CGImage {
    let width = 200
    let height = 200
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
    for rect in changedRects { context.fill(rect) }
    return try #require(context.makeImage())
}
