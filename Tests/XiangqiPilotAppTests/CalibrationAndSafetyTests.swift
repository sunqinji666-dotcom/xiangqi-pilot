import CoreGraphics
import Foundation
import Testing
@testable import XiangqiPilotApp

@Suite struct CalibrationAndSafetyTests {
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

    @Test func geometryHashChangesWhenWindowMoves() throws {
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
        #expect(first.geometryHash != moved.geometryHash)
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
}
