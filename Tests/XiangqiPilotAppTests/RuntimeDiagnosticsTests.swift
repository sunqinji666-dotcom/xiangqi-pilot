import Foundation
import Testing
@testable import XiangqiPilotApp

@Suite struct RuntimeDiagnosticsTests {
    @Test func backgroundConfirmationUsesDirectTargetActivation() {
        #expect(
            ClickExecutor.activationRoute(
                frontmostPID: 52314,
                currentPID: 98571,
                targetPID: 90168
            ) == .direct
        )
        #expect(
            ClickExecutor.activationRoute(
                frontmostPID: 98571,
                currentPID: 98571,
                targetPID: 90168
            ) == .cooperative
        )
        #expect(
            ClickExecutor.activationRoute(
                frontmostPID: 90168,
                currentPID: 98571,
                targetPID: 90168
            ) == .alreadyFrontmost
        )
    }

    @Test func accessibilityFallbackRequiresOneExactGeometryMatch() {
        let target = CGRect(x: 885, y: -859, width: 788, height: 619)
        let frames = [
            CGRect(x: 895, y: -855, width: 66, height: 20),
            target,
            CGRect(x: 157, y: -926, width: 1_228, height: 860)
        ]

        #expect(
            ClickExecutor.uniqueMatchingAXWindowIndex(
                frames: frames,
                expectedFrame: target
            ) == 1
        )
        #expect(
            ClickExecutor.uniqueMatchingAXWindowIndex(
                frames: [target.offsetBy(dx: 0.25, dy: 0)],
                expectedFrame: target
            ) == nil
        )
        #expect(
            ClickExecutor.uniqueMatchingAXWindowIndex(
                frames: [CGRect(x: 885, y: -859, width: 788.25, height: 619)],
                expectedFrame: target
            ) == nil
        )
        #expect(
            ClickExecutor.uniqueMatchingAXWindowIndex(
                frames: [target, target],
                expectedFrame: target
            ) == nil
        )
    }

    @Test func clickExecutorDiagnosticPreservesExactCaseAndLocalizedDetail() {
        let diagnostic = PilotDiagnostic(
            error: ClickExecutorError.unexpectedWindowLayer(7)
        )

        #expect(diagnostic.source == "ClickExecutor")
        #expect(diagnostic.code == "unexpectedWindowLayer")
        #expect(diagnostic.message == "目标窗口层级异常：7")
        #expect(
            diagnostic.displayText
                == "[ClickExecutor.unexpectedWindowLayer] 目标窗口层级异常：7"
        )
    }

    @Test func representativeClickFailuresProduceSearchableDiagnosticText() {
        let errors: [ClickExecutorError] = [
            .notArmed,
            .targetNotFrontmost,
            .targetWindowOccluded,
            .frameContentChanged,
            .roiViolation,
            .verificationBoardStateUnchanged
        ]

        for error in errors {
            let diagnostic = PilotDiagnostic(error: error)
            #expect(!diagnostic.code.isEmpty)
            #expect(diagnostic.displayText.contains("[ClickExecutor.\(diagnostic.code)]"))
            #expect(diagnostic.displayText.contains(error.localizedDescription))
        }
    }

    @Test func nonClickFailuresRemainIdentifiableAsRuntimeFailures() {
        let error = NSError(
            domain: "RuntimeDiagnosticsTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "识别服务不可用"]
        )
        let diagnostic = PilotDiagnostic(error: error)

        #expect(diagnostic.source == "PilotRuntime")
        #expect(diagnostic.code == "operationFailed")
        #expect(diagnostic.displayText == "[PilotRuntime.operationFailed] 识别服务不可用")
    }
}
