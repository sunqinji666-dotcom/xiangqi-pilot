import Foundation
import OSLog

struct PilotDiagnostic: Equatable, Sendable {
    let source: String
    let code: String
    let message: String

    init(error: Error) {
        if let clickError = error as? ClickExecutorError {
            source = "ClickExecutor"
            code = clickError.diagnosticCode
            message = clickError.localizedDescription
        } else if let gridClickError = error as? GridClickExecutorError {
            source = "GridClickExecutor"
            code = gridClickError.diagnosticCode
            message = gridClickError.localizedDescription
        } else {
            source = "PilotRuntime"
            code = "operationFailed"
            message = error.localizedDescription
        }
    }

    var displayText: String {
        "[\(source).\(code)] \(message)"
    }
}

extension GridClickExecutorError {
    var diagnosticCode: String {
        switch self {
        case .notArmed: "notArmed"
        case .actionInFlight: "actionInFlight"
        case .permissionMissing: "permissionMissing"
        case .targetMissing: "targetMissing"
        case .targetNotFrontmost: "targetNotFrontmost"
        case .targetChanged: "targetChanged"
        case .geometryChanged: "geometryChanged"
        case .staleFrame: "staleFrame"
        case .pointOutsideTarget: "pointOutsideTarget"
        case .eventCreationFailed: "eventCreationFailed"
        case .verificationUnchanged: "verificationUnchanged"
        }
    }
}

extension ClickExecutorError {
    /// A stable identifier that remains searchable even when the localized
    /// human-readable message changes.
    var diagnosticCode: String {
        switch self {
        case .notArmed: "notArmed"
        case .anotherActionInFlight: "anotherActionInFlight"
        case .accessibilityPermissionMissing: "accessibilityPermissionMissing"
        case .screenRecordingPermissionMissing: "screenRecordingPermissionMissing"
        case .targetMismatch: "targetMismatch"
        case .targetWindowMissing: "targetWindowMissing"
        case .targetNotOnScreen: "targetNotOnScreen"
        case .unexpectedWindowLayer: "unexpectedWindowLayer"
        case .targetNotFrontmost: "targetNotFrontmost"
        case .targetWindowOccluded: "targetWindowOccluded"
        case .geometryHashMismatch: "geometryHashMismatch"
        case .windowGeometryChanged: "windowGeometryChanged"
        case .imageGeometryChanged: "imageGeometryChanged"
        case .frameOlderThanBinding: "frameOlderThanBinding"
        case .frameAdvancedTooFar: "frameAdvancedTooFar"
        case .frameContentChanged: "frameContentChanged"
        case .frameFingerprintUnavailable: "frameFingerprintUnavailable"
        case .frameNotStable: "frameNotStable"
        case .emptyBoardStateHash: "emptyBoardStateHash"
        case .sourceEqualsDestination: "sourceEqualsDestination"
        case .roiViolation: "roiViolation"
        case .eventCreationFailed: "eventCreationFailed"
        case .interrupted: "interrupted"
        case .noMatchingPendingReceipt: "noMatchingPendingReceipt"
        case .verificationFrameMissing: "verificationFrameMissing"
        case .verificationFrameUnstable: "verificationFrameUnstable"
        case .verificationSawNoVisualChange: "verificationSawNoVisualChange"
        case .verificationBoardStateUnchanged: "verificationBoardStateUnchanged"
        }
    }
}

enum PilotDiagnosticLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jacksun.xiangqi-pilot",
        category: "PilotRuntime"
    )

    static func blockingError(_ message: String) {
        logger.error("blocking_error: \(message, privacy: .public)")
    }

    static func timing(_ stage: String, milliseconds: Double) {
        logger.info(
            "timing stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, format: .fixed(precision: 1))"
        )
    }

    static func event(_ message: String) {
        logger.info("event: \(message, privacy: .public)")
    }
}
