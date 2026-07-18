import XCTest
@testable import VoiceOpsCore

/// Exit criterion (Phase 1): state transitions are deterministic and tested.
/// The machine is a pure reducer: (state, event) -> state?, nil meaning the
/// event is ignored in that state. No timers, no side effects.
final class SessionStateMachineTests: XCTestCase {

    // MARK: Happy path

    func testHotkeyStartsListeningFromIdle() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.idle, .hotkeyTapped),
            .listening(transcript: ""))
    }

    func testPartialTranscriptUpdatesListening() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "remind"), .partialTranscript("remind me")),
            .listening(transcript: "remind me"))
    }

    func testHotkeyEndsCaptureIntoPlanning() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "remind me"), .hotkeyTapped),
            .planning(transcript: "remind me"))
    }

    func testFinalTranscriptAlsoEndsCaptureIntoPlanning() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "remind"), .finalTranscript("remind me tomorrow")),
            .planning(transcript: "remind me tomorrow"))
    }

    func testFinalTranscriptRefinesPlanningTranscript() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.planning(transcript: "remind"), .finalTranscript("remind me tomorrow")),
            .planning(transcript: "remind me tomorrow"))
    }

    func testPlanReadyMovesToActing() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.planning(transcript: "t"), .planReady(summary: "one verified write")),
            .acting(description: "one verified write"))
    }

    func testVerificationStartedMovesToVerifying() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.acting(description: "d"), .verificationStarted),
            .verifying)
    }

    func testTaskCompletedShowsResultFromVerifying() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.verifying, .taskCompleted(state: .succeeded, summary: "done")),
            .result(.completed(state: .succeeded, summary: "done")))
    }

    func testTaskCompletedAlsoAcceptedFromActing() {
        // The Phase 1 mock sidecar completes without a separate verification event.
        XCTAssertEqual(
            SessionStateMachine.reduce(.acting(description: "d"), .taskCompleted(state: .succeeded, summary: "ok")),
            .result(.completed(state: .succeeded, summary: "ok")))
    }

    func testDismissReturnsToIdle() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.result(.cancelled), .dismissResult),
            .idle)
    }

    // MARK: Cancellation — reachable from every active state

    func testStopDuringListeningReturnsToIdleQuietly() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "x"), .stopRequested),
            .idle)
    }

    func testStopDuringPlanningActingVerifyingShowsCancelledResult() {
        for state: SessionState in [.planning(transcript: "t"), .acting(description: "d"), .verifying] {
            XCTAssertEqual(
                SessionStateMachine.reduce(state, .stopRequested),
                .result(.cancelled),
                "stop in \(state) should surface a cancelled result")
        }
    }

    // MARK: Failure

    func testTaskFailedShowsFailureFromAnyActiveTaskState() {
        for state: SessionState in [.planning(transcript: "t"), .acting(description: "d"), .verifying] {
            XCTAssertEqual(
                SessionStateMachine.reduce(state, .taskFailed(reason: "INVALID_MESSAGE")),
                .result(.failed(reason: "INVALID_MESSAGE")),
                "failure in \(state) should surface a failed result")
        }
    }

    // MARK: Determinism — illegal pairs are explicit no-ops

    func testIllegalEventsAreIgnored() {
        let ignored: [(SessionState, SessionEvent)] = [
            (.idle, .planReady(summary: "s")),
            (.idle, .partialTranscript("p")),
            (.idle, .stopRequested),
            (.idle, .taskCompleted(state: .succeeded, summary: "s")),
            (.listening(transcript: ""), .planReady(summary: "s")),
            (.verifying, .partialTranscript("p")),
            (.result(.cancelled), .stopRequested),
            (.result(.cancelled), .hotkeyTapped),
            (.planning(transcript: "t"), .hotkeyTapped),
        ]
        for (state, event) in ignored {
            XCTAssertNil(
                SessionStateMachine.reduce(state, event),
                "\(event) in \(state) must be ignored")
        }
    }

    func testReducerIsPure() {
        let state = SessionState.listening(transcript: "abc")
        let first = SessionStateMachine.reduce(state, .partialTranscript("abcd"))
        let second = SessionStateMachine.reduce(state, .partialTranscript("abcd"))
        XCTAssertEqual(first, second)
    }
}
