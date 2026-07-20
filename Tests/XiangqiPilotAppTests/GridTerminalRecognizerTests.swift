import Testing
@testable import XiangqiPilotApp

struct GridTerminalRecognizerTests {
    @Test func recognizesTerminalLabels() {
        #expect(GridTerminalRecognizer.classify(text: "本局失败") == .loss)
        #expect(GridTerminalRecognizer.classify(text: "恭喜获得胜利") == .win)
        #expect(GridTerminalRecognizer.classify(text: "结果：和棋") == .draw)
        #expect(GridTerminalRecognizer.classify(
            text: "五子棋 失败 本局步数 14 当前积分 0 继续"
        ) == .loss)
        #expect(GridTerminalRecognizer.classify(text: "继续游戏") == nil)
        #expect(GridTerminalRecognizer.isTerminalOverlay(text: "对局结束"))
        #expect(!GridTerminalRecognizer.isTerminalOverlay(text: "本局进行中"))
    }

    @Test func tencentPaidConfirmationIsClassifiedBeforeAnyFallbackClick() {
        #expect(TencentGoModalClassifier.requiresPaidConfirmation(
            ocrTexts: ["今天免费对局数已用完", "之后每局将消耗15万金币", "确定开始吗？"]
        ))
        #expect(TencentGoModalClassifier.requiresPaidConfirmation(
            ocrTexts: ["消耗金币", "确定开始"]
        ))
        #expect(!TencentGoModalClassifier.requiresPaidConfirmation(
            ocrTexts: ["AI训练", "开始对局", "认输"]
        ))
    }
}
