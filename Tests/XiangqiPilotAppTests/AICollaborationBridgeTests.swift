import XCTest
@testable import XiangqiPilotApp

final class AICollaborationBridgeTests: XCTestCase {
    func testAIRecognizedPositionRoundTripsWithFrameBinding() throws {
        let envelope = AIBridgeEnvelope(
            id: "recognition-1",
            type: .aiRecognizedPosition,
            payload: AIBridgePayload(
                windowID: 6524,
                ownerPID: 83993,
                fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1",
                confidence: 1,
                frameSequence: 638
            )
        )

        let decoded = try JSONDecoder().decode(
            AIBridgeEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        XCTAssertEqual(decoded.type, .aiRecognizedPosition)
        XCTAssertEqual(decoded.payload.windowID, 6524)
        XCTAssertEqual(decoded.payload.frameSequence, 638)
        XCTAssertEqual(decoded.payload.fen, envelope.payload.fen)
    }
}
