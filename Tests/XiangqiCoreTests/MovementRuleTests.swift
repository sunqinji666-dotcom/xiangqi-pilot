import Testing
@testable import XiangqiCore

@Suite struct MovementRuleTests {
    @Test func chariotSlidesCapturesAndStopsAtFirstPiece() {
        let origin = square(4, 5)
        let position = board([
            (piece(.red, .chariot), origin),
            (piece(.black, .soldier), square(4, 3)),
            (piece(.red, .soldier), square(4, 7)),
            (piece(.black, .horse), square(6, 5)),
            (piece(.red, .advisor), square(2, 5))
        ])

        let destinations = destinationsOfPiece(at: origin, on: position, side: .red)
        #expect(destinations == Set([
            square(4, 4), square(4, 3), square(4, 6),
            square(5, 5), square(6, 5), square(3, 5)
        ]))
    }

    @Test func horseLegBlocksBothJumpsOnThatSide() {
        let origin = square(4, 5)
        var position = Board()
        position[origin] = piece(.red, .horse)
        position[square(5, 5)] = piece(.red, .soldier)

        let destinations = destinationsOfPiece(at: origin, on: position, side: .red)
        #expect(!destinations.contains(square(6, 4)))
        #expect(!destinations.contains(square(6, 6)))
        #expect(destinations.contains(square(2, 4)))
        #expect(destinations.contains(square(3, 3)))
        #expect(destinations.count == 6)
    }

    @Test func elephantEyeAndRiverRestriction() {
        var eyeBlocked = Board()
        let origin = square(4, 7)
        eyeBlocked[origin] = piece(.red, .elephant)
        eyeBlocked[square(3, 6)] = piece(.black, .soldier)

        let blockedDestinations = destinationsOfPiece(at: origin, on: eyeBlocked, side: .red)
        #expect(!blockedDestinations.contains(square(2, 5)))
        #expect(blockedDestinations.contains(square(6, 5)))
        #expect(blockedDestinations.contains(square(2, 9)))
        #expect(blockedDestinations.contains(square(6, 9)))

        var riverBoard = Board()
        let riverOrigin = square(4, 5)
        riverBoard[riverOrigin] = piece(.red, .elephant)
        let riverDestinations = destinationsOfPiece(at: riverOrigin, on: riverBoard, side: .red)
        #expect(riverDestinations == Set([square(2, 7), square(6, 7)]))
    }

    @Test func advisorAndGeneralStayInsidePalace() {
        var advisorBoard = Board()
        let advisorOrigin = square(4, 8)
        advisorBoard[advisorOrigin] = piece(.red, .advisor)
        #expect(
            destinationsOfPiece(at: advisorOrigin, on: advisorBoard, side: .red)
                == Set([square(3, 7), square(5, 7), square(3, 9), square(5, 9)])
        )

        var generalBoard = Board()
        let generalOrigin = square(3, 9)
        generalBoard[generalOrigin] = piece(.red, .general)
        #expect(
            destinationsOfPiece(at: generalOrigin, on: generalBoard, side: .red)
                == Set([square(3, 8), square(4, 9)])
        )
    }

    @Test func flyingGeneralCaptureAndFacingDetection() {
        let position = board([
            (piece(.black, .general), square(4, 0)),
            (piece(.red, .general), square(4, 9))
        ])

        #expect(position.generalsFaceEachOther())
        #expect(position.isInCheck(.red))
        #expect(position.isInCheck(.black))
        #expect(
            position.pseudoLegalMoves(for: .red).contains(
                Move(from: square(4, 9), to: square(4, 0))
            )
        )

        var blocked = position
        blocked[square(4, 5)] = piece(.red, .soldier)
        #expect(!blocked.generalsFaceEachOther())
    }

    @Test func cannonNeedsExactlyOneScreenToCapture() {
        let origin = square(0, 9)
        var position = Board()
        position[origin] = piece(.red, .cannon)
        position[square(0, 6)] = piece(.red, .soldier)
        position[square(0, 3)] = piece(.black, .chariot)
        position[square(0, 1)] = piece(.black, .horse)

        var destinations = destinationsOfPiece(at: origin, on: position, side: .red)
        #expect(destinations.contains(square(0, 8)))
        #expect(destinations.contains(square(0, 7)))
        #expect(destinations.contains(square(0, 3)))
        #expect(!destinations.contains(square(0, 6)))
        #expect(!destinations.contains(square(0, 5)))
        #expect(!destinations.contains(square(0, 1)))

        position[square(0, 5)] = piece(.black, .soldier)
        destinations = destinationsOfPiece(at: origin, on: position, side: .red)
        #expect(destinations.contains(square(0, 5)))
        #expect(!destinations.contains(square(0, 3)))
    }

    @Test func soldierGainsSidewaysMovesOnlyAfterCrossingRiver() {
        var position = Board()
        position[square(4, 5)] = piece(.red, .soldier)
        #expect(
            destinationsOfPiece(at: square(4, 5), on: position, side: .red)
                == Set([square(4, 4)])
        )

        position[square(4, 5)] = nil
        position[square(4, 4)] = piece(.red, .soldier)
        #expect(
            destinationsOfPiece(at: square(4, 4), on: position, side: .red)
                == Set([square(4, 3), square(3, 4), square(5, 4)])
        )

        position = Board()
        position[square(4, 5)] = piece(.black, .soldier)
        #expect(
            destinationsOfPiece(at: square(4, 5), on: position, side: .black)
                == Set([square(4, 6), square(3, 5), square(5, 5)])
        )
    }

    @Test func noPieceMayCaptureFriendlyPiece() {
        var position = Board()
        position[square(4, 5)] = piece(.red, .chariot)
        position[square(4, 3)] = piece(.red, .horse)

        let destinations = destinationsOfPiece(at: square(4, 5), on: position, side: .red)
        #expect(destinations.contains(square(4, 4)))
        #expect(!destinations.contains(square(4, 3)))
        #expect(!destinations.contains(square(4, 2)))
    }

    private func destinationsOfPiece(
        at origin: Square,
        on board: Board,
        side: Side
    ) -> Set<Square> {
        Set(
            board.pseudoLegalMoves(for: side)
                .filter { $0.from == origin }
                .map(\.to)
        )
    }
}
