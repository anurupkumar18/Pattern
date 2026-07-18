import XCTest
@testable import VoiceOpsCore

final class RecoveryPolicyTests: XCTestCase {
    private func error(_ code: String, details: [String: JSONValue] = [:]) -> StructuredError {
        StructuredError(code: code, message: "fixture failure", details: details)
    }

    func testPermissionDenialStopsForExactSettingsPath() {
        let decision = RecoveryPolicy.decide(
            status: .failed,
            error: error("PERMISSION_DENIED", details: ["settings_url": .string("settings://x")]),
            risk: .reversibleWrite, attempt: 1, maxAttempts: 2)

        XCTAssertEqual(decision, .requestPermission(settingsURL: "settings://x"))
    }

    func testNoStateChangeRetriesOnlyInsideBudget() {
        XCTAssertEqual(
            RecoveryPolicy.decide(
                status: .failed, error: error("NO_STATE_CHANGE"),
                risk: .reversibleWrite, attempt: 1, maxAttempts: 2),
            .retrySameTarget(
                reason: "No committed state change was observed; retrying the same semantic target once."))
        XCTAssertEqual(
            RecoveryPolicy.decide(
                status: .failed, error: error("NO_STATE_CHANGE"),
                risk: .reversibleWrite, attempt: 2, maxAttempts: 2),
            .stop(reason: "The bounded recovery budget is exhausted."))
    }

    func testUncertainOrConsequentialActionNeverRetries() {
        if case .verifyWithoutRetry = RecoveryPolicy.decide(
            status: .uncertain, error: error("TIMEOUT"),
            risk: .reversibleWrite, attempt: 1, maxAttempts: 2
        ) {} else { XCTFail("uncertain state must not retry") }

        if case .verifyWithoutRetry = RecoveryPolicy.decide(
            status: .failed, error: error("NO_STATE_CHANGE"),
            risk: .consequential, attempt: 1, maxAttempts: 2
        ) {} else { XCTFail("consequential state must not retry") }
    }

    func testLedgerRejectsDuplicateCompletedAndUncertainAttempts() {
        let taskID = UUID()
        var ledger = ActionAttemptLedger()
        XCTAssertEqual(
            ledger.claim(taskID: taskID, stepID: "write", maxAttempts: 2),
            .allowed(attempt: 1))
        ledger.finish(taskID: taskID, stepID: "write", status: .executed)
        XCTAssertEqual(
            ledger.claim(taskID: taskID, stepID: "write", maxAttempts: 2),
            .rejectedCompleted)

        XCTAssertEqual(
            ledger.claim(taskID: taskID, stepID: "other", maxAttempts: 2),
            .allowed(attempt: 1))
        ledger.finish(taskID: taskID, stepID: "other", status: .uncertain)
        XCTAssertEqual(
            ledger.claim(taskID: taskID, stepID: "other", maxAttempts: 2),
            .rejectedUncertain)
    }

    func testTraceCapturesRecoveryCountAndElapsedTime() {
        let start = Date(timeIntervalSince1970: 100)
        var trace = TaskTrace(startedAt: start)
        trace.record(.planning, "Plan ready", at: start.addingTimeInterval(0.1))
        trace.record(.recovery, "Retry once", at: start.addingTimeInterval(0.25))

        XCTAssertEqual(trace.recoveryCount, 1)
        XCTAssertEqual(trace.totalElapsedMilliseconds, 250)
    }

    func testPanicStopOnlyConsumesEscapeWhileArmed() {
        XCTAssertTrue(PanicStopPolicy.shouldCancel(keyCode: 53, isArmed: true))
        XCTAssertFalse(PanicStopPolicy.shouldCancel(keyCode: 53, isArmed: false))
        XCTAssertFalse(PanicStopPolicy.shouldCancel(keyCode: 9, isArmed: true))
    }
}
