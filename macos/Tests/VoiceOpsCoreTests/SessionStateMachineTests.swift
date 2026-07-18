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

    func testHotkeyEndsCaptureIntoGrounding() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "remind me"), .hotkeyTapped),
            .grounding(transcript: "remind me"))
    }

    func testFinalTranscriptAlsoEndsCaptureIntoGrounding() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.listening(transcript: "remind"), .finalTranscript("remind me tomorrow")),
            .grounding(transcript: "remind me tomorrow"))
    }

    func testFinalTranscriptRefinesGroundingTranscript() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.grounding(transcript: "remind"), .finalTranscript("remind me tomorrow")),
            .grounding(transcript: "remind me tomorrow"))
    }

    func testGroundingReadyMovesToPlanningWithReferenceChips() {
        let chips = [GroundingChip(
            phrase: "that deadline", resolvedText: "July 31, 2026",
            source: .accessibility, confidence: 0.98)]
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .grounding(transcript: "use that deadline"),
                .groundingReady(chips)),
            .planning(transcript: "use that deadline", groundingChips: chips))
    }

    func testPlanReadyMovesToActing() {
        let chips = [GroundingChip(
            phrase: "this email", resolvedText: "Hackathon details",
            source: .accessibility, confidence: 1)]
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .planning(transcript: "t", groundingChips: chips),
                .planReady(summary: "one verified write")),
            .acting(description: "one verified write", groundingChips: chips))
    }

    func testVerificationStartedMovesToVerifying() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.acting(description: "d", groundingChips: []), .verificationStarted),
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
            SessionStateMachine.reduce(
                .acting(description: "d", groundingChips: []),
                .taskCompleted(state: .succeeded, summary: "ok")),
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

    func testStopDuringGroundingPlanningActingVerifyingShowsCancelledResult() {
        for state: SessionState in [
            .grounding(transcript: "t"),
            .planning(transcript: "t", groundingChips: []),
            .acting(description: "d", groundingChips: []),
            .verifying,
        ] {
            XCTAssertEqual(
                SessionStateMachine.reduce(state, .stopRequested),
                .result(.cancelled),
                "stop in \(state) should surface a cancelled result")
        }
    }

    // MARK: Failure

    func testTaskFailedShowsFailureFromAnyActiveState() {
        // Includes .listening: capture failures (mic/speech permission denied,
        // recognizer unavailable) must surface an actionable result, not vanish.
        for state: SessionState in [
            .listening(transcript: ""), .grounding(transcript: "t"),
            .planning(transcript: "t", groundingChips: []),
            .acting(description: "d", groundingChips: []), .verifying,
        ] {
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
            (.planning(transcript: "t", groundingChips: []), .hotkeyTapped),
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
