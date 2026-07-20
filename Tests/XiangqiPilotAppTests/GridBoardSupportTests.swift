import CoreGraphics
import Testing
import XiangqiCore
@testable import XiangqiPilotApp

struct GridBoardSupportTests {
    @Test func squareGridCalibrationMapsCornersAndCentre() throws {
        let calibration = try GridBoardCalibration(
            corners: BoardCorners(
                topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 110, y: 20),
                bottomLeft: CGPoint(x: 10, y: 120), bottomRight: CGPoint(x: 110, y: 120)
            ),
            imageSize: CGSize(width: 140, height: 140),
            windowFrame: CGRect(x: 300, y: 400, width: 140, height: 140),
            lineCount: 11
        )
        #expect(try calibration.imagePoint(for: GridCoordinate(column: 0, row: 0)) == CGPoint(x: 10, y: 20))
        #expect(try calibration.imagePoint(for: GridCoordinate(column: 10, row: 10)) == CGPoint(x: 110, y: 120))
        #expect(try calibration.imagePoint(for: GridCoordinate(column: 5, row: 5)) == CGPoint(x: 60, y: 70))
    }

    @Test func localRecognizerClassifiesSyntheticBlackAndWhiteStones() throws {
        let width = 180, height = 180
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.68, green: 0.54, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        context.fillEllipse(in: CGRect(x: 73, y: 73, width: 34, height: 34))
        // Core Graphics drawing has a bottom-left origin while CGImage crop
        // coordinates are top-left.  Place this at visual row 0 accordingly.
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fillEllipse(in: CGRect(x: 13, y: 133, width: 34, height: 34))
        // The active move in several local clients carries a pale centre
        // marker.  Its disc is still a black stone, even though fewer than
        // 60% of the sample pixels are dark.
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fillEllipse(in: CGRect(x: 133, y: 133, width: 34, height: 34))
        context.setFillColor(CGColor(gray: 0.72, alpha: 1))
        context.fillEllipse(in: CGRect(x: 144, y: 144, width: 12, height: 12))
        // Tencent Go uses a dark last-move wedge on a white stone. It must
        // stay classified as white rather than being dropped as ambiguous.
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fillEllipse(in: CGRect(x: 13, y: 13, width: 34, height: 34))
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fillEllipse(in: CGRect(x: 26, y: 26, width: 12, height: 12))
        // A wood-coloured star point is dark but not neutral. It must remain
        // empty rather than becoming a phantom black stone on a fresh board.
        context.setFillColor(CGColor(red: 0.32, green: 0.16, blue: 0.05, alpha: 1))
        context.fillEllipse(in: CGRect(x: 133, y: 13, width: 34, height: 34))
        let image = try #require(context.makeImage())
        let calibration = try GridBoardCalibration(
            corners: BoardCorners(
                topLeft: CGPoint(x: 30, y: 30), topRight: CGPoint(x: 150, y: 30),
                bottomLeft: CGPoint(x: 30, y: 150), bottomRight: CGPoint(x: 150, y: 150)
            ),
            imageSize: CGSize(width: width, height: height),
            windowFrame: CGRect(x: 0, y: 0, width: width, height: height),
            lineCount: 5
        )
        let snapshot = GridStoneRecognizer.recognize(image: image, calibration: calibration)
        #expect(snapshot.stones[GridCoordinate(column: 2, row: 2)] == .black)
        #expect(snapshot.stones[GridCoordinate(column: 0, row: 0)] == .white)
        #expect(snapshot.stones[GridCoordinate(column: 4, row: 0)] == .black)
        #expect(snapshot.stones[GridCoordinate(column: 0, row: 4)] == .white)
        #expect(snapshot.stones[GridCoordinate(column: 4, row: 4)] == nil)
    }
}
