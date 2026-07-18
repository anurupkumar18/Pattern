import XCTest
@testable import VoiceOpsCore

final class ExchangeValidatorTests: XCTestCase {
    let taskID = UUID(uuidString: "B3E9A1C2-6D4F-4A8B-9C0D-1E2F3A4B5C6D")!

    private func planEnvelope(taskID: UUID? = nil) -> Envelope {
        let step = TaskStep(
            id: "step-1", description: "d", tool: "reminders.create", arguments: [:],
            preconditions: [],
            postconditions: [Predicate(id: "p1", description: "exists", expected: [:])],
            risk: .reversibleWrite, requiresConfirmation: false, fallbackTools: [],
            maxAttempts: 2, timeoutSeconds: 30,
            verifier: VerifierSpec(kind: "structured", description: "fetch back"))
        return Envelope(
            type: .planReady, taskID: taskID ?? self.taskID,
            payload: .planReady(TaskPlan(goal: "g", summary: "s", steps: [step])))
    }

    private func completedEnvelope(state: TaskState = .succeeded, passed: Bool = true) -> Envelope {
        let verification = VerificationResult(
            predicateId: "p1", passed: passed, method: "schema_validation", confidence: 1.0,
            expected: [:], observed: [:], evidenceIds: [], failureReason: passed ? nil : "nope")
        return Envelope(
            type: .taskCompleted, taskID: taskID,
            payload: .taskCompleted(TaskCompleted(state: state, summary: "ok", verification: [verification])))
    }

    func testAcceptsPlanThenVerifiedCompletion() throws {
        let outcome = ExchangeValidator.validate(
            responses: [planEnvelope(), completedEnvelope()], requestTaskID: taskID)
        guard case .success(let exchange) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(exchange.plan.steps.count, 1)
        XCTAssertEqual(exchange.completion.state, .succeeded)
    }

    func testRejectsMismatchedTaskID() {
        let outcome = ExchangeValidator.validate(
            responses: [planEnvelope(taskID: UUID()), completedEnvelope()], requestTaskID: taskID)
        guard case .failure(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("task_id"), reason)
    }

    func testRejectsCompletionWithoutPlan() {
        let outcome = ExchangeValidator.validate(
            responses: [completedEnvelope()], requestTaskID: taskID)
        guard case .failure = outcome else { return XCTFail("expected failure") }
    }

    func testRejectsSuccessClaimWithFailedVerification() {
        // Defense in depth for CLAUDE.md invariant 2 on the client side.
        let outcome = ExchangeValidator.validate(
            responses: [planEnvelope(), completedEnvelope(state: .succeeded, passed: false)],
            requestTaskID: taskID)
        guard case .failure(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("verification"), reason)
    }

    func testReportsSidecarTaskFailure() {
        let failure = Envelope(
            type: .taskFailed, taskID: taskID,
            payload: .taskFailed(TaskFailure(
                error: StructuredError(code: "INVALID_MESSAGE", message: "bad", details: [:]),
                summary: nil)))
        let outcome = ExchangeValidator.validate(responses: [failure], requestTaskID: taskID)
        guard case .failure(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("INVALID_MESSAGE"), reason)
    }
}
