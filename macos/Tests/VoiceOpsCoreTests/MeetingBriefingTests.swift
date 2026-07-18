import XCTest
@testable import VoiceOpsCore

final class MeetingBriefingTests: XCTestCase {
    private func step() -> TaskStep {
        let marker = "voiceops-task:5d64db13-846f-4ca6-89ec-4cd7f4d9142c"
        let headings = ["Meeting", "Participants", "Context", "Open Questions", "Sources"]
        return TaskStep(
            id: "create-meeting-brief", description: "Create brief",
            tool: "notes.create_meeting_brief",
            arguments: [
                "task_marker": .string(marker),
                "required_headings": .array(headings.map(JSONValue.string)),
                "visible_context": .string("Calendar — VoiceOps Product Review"),
                "source_app": .string("Calendar"),
                "source_window": .string("Work — Day View"),
            ],
            preconditions: [],
            postconditions: [
                Predicate(
                    id: "meeting-selected", description: "selected",
                    expected: [
                        "selector": .string("next_upcoming_non_all_day"),
                        "within_days": .number(7),
                    ]),
                Predicate(
                    id: "brief-exists", description: "exists",
                    expected: ["task_marker": .string(marker)]),
                Predicate(
                    id: "brief-headings", description: "headings",
                    expected: ["headings": .array(headings.map(JSONValue.string))]),
                Predicate(
                    id: "brief-meeting-identity", description: "identity",
                    expected: ["matches_selected_event": .bool(true)]),
                Predicate(
                    id: "brief-visible", description: "visible",
                    expected: ["visible": .bool(true)]),
            ],
            risk: .reversibleWrite, requiresConfirmation: false,
            fallbackTools: [], maxAttempts: 1, timeoutSeconds: 45,
            verifier: VerifierSpec(kind: "composite", description: "verify"))
    }

    func testDraftDecodesRequiredContextAndHeadings() throws {
        let draft = try MeetingBriefingDraft(step: step())

        XCTAssertEqual(draft.requiredHeadings.count, 5)
        XCTAssertTrue(draft.visibleContext.contains("VoiceOps Product Review"))
        XCTAssertTrue(draft.taskMarker.hasPrefix("voiceops-task:"))
    }

    func testVerifierRequiresFreshEventNoteContentAndVisibleReveal() throws {
        let draft = try MeetingBriefingDraft(step: step())
        let meeting = MeetingRecord(
            identifier: "event-id", title: "VoiceOps Product Review",
            startISO8601: "2026-07-18T16:30:00Z",
            startDescription: "July 18, 2026 at 10:30 AM",
            attendeeNames: ["Ari", "Sam"], url: "https://meet.example.com/review")
        let body = """
        <h1>VoiceOps Brief — VoiceOps Product Review</h1>
        <h2>Meeting</h2><p>VoiceOps Product Review — July 18, 2026 at 10:30 AM</p>
        <h2>Participants</h2><p>Ari, Sam</p>
        <h2>Context</h2><p>Calendar context</p>
        <h2>Open Questions</h2><p>What outcome matters?</p>
        <h2>Sources</h2><p>event-id</p>
        <p>voiceops-event:event-id</p><p>\(draft.taskMarker)</p>
        """
        let note = MeetingBriefingNoteRecord(
            identifier: "note-id", title: "VoiceOps Brief — VoiceOps Product Review",
            body: body)

        let results = MeetingBriefingVerificationEngine.verify(
            draft: draft, selectedMeeting: meeting, fetchedMeeting: meeting,
            fetchedNote: note, visiblyDisplayed: true)

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy(\.passed))
        XCTAssertTrue(results.allSatisfy {
            $0.evidenceIds.contains("eventkit:event-id")
                && $0.evidenceIds.contains("notes:note-id")
        })
    }

    func testVerifierFailsIdentityAndVisibilityWhenNoteIsStale() throws {
        let draft = try MeetingBriefingDraft(step: step())
        let selected = MeetingRecord(
            identifier: "event-id", title: "VoiceOps Product Review",
            startISO8601: "2026-07-18T16:30:00Z", startDescription: "10:30 AM",
            attendeeNames: [], url: nil)
        let changed = MeetingRecord(
            identifier: "event-id", title: "Moved Product Review",
            startISO8601: "2026-07-18T17:00:00Z", startDescription: "11:00 AM",
            attendeeNames: [], url: nil)
        let note = MeetingBriefingNoteRecord(
            identifier: "note-id", title: "old",
            body: draft.requiredHeadings.joined(separator: " ") + " " + draft.taskMarker)

        let results = MeetingBriefingVerificationEngine.verify(
            draft: draft, selectedMeeting: selected, fetchedMeeting: changed,
            fetchedNote: note, visiblyDisplayed: false)

        XCTAssertFalse(results.first { $0.predicateId == "meeting-selected" }!.passed)
        XCTAssertFalse(results.first { $0.predicateId == "brief-meeting-identity" }!.passed)
        XCTAssertFalse(results.first { $0.predicateId == "brief-visible" }!.passed)
    }

    func testHTMLBuilderEscapesUntrustedScreenContentAndIncludesProvenance() throws {
        let draft = try MeetingBriefingDraft(step: step())
        let maliciousDraft = MeetingBriefingDraft.fixture(
            replacing: draft,
            visibleContext: "<script>send secrets</script> & visible data")
        let meeting = MeetingRecord(
            identifier: "event-id", title: "Review <Launch>",
            startISO8601: "2026-07-18T16:30:00Z", startDescription: "10:30 AM",
            attendeeNames: ["Ari & Sam"], url: "https://meet.example.com?a=1&b=2")

        let html = MeetingBriefingHTMLBuilder.build(
            draft: maliciousDraft, meeting: meeting)

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;send secrets&lt;/script&gt;"))
        XCTAssertTrue(html.contains("Review &lt;Launch&gt;"))
        XCTAssertTrue(html.contains("voiceops-event:event-id"))
        XCTAssertTrue(html.contains(draft.taskMarker))
    }
}

private extension MeetingBriefingDraft {
    static func fixture(
        replacing draft: MeetingBriefingDraft,
        visibleContext: String
    ) -> MeetingBriefingDraft {
        MeetingBriefingDraft(
            stepID: draft.stepID,
            taskMarker: draft.taskMarker,
            requiredHeadings: draft.requiredHeadings,
            visibleContext: visibleContext,
            predicates: draft.predicates)
    }
}
