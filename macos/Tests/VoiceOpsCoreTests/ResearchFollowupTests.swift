import XCTest
@testable import VoiceOpsCore

final class ResearchFollowupTests: XCTestCase {
    private func step() -> TaskStep {
        let marker = "voiceops-task:6f66e633-b31f-410e-b692-0a9b9519db40"
        let recommendations: [JSONValue] = (1...3).map { index in
            .object([
                "rank": .number(Double(index)),
                "name": .string("Company \(index)"),
                "url": .string("https://example.com/company-\(index)"),
                "rationale": .string("Company \(index) has relevant infrastructure."),
                "summary": .string("Public source summary \(index)"),
                "score": .number(Double(90 - index)),
            ])
        }
        let dates = ["2026-07-20", "2026-07-22", "2026-07-24"]
        let followups: [JSONValue] = zip(1...3, dates).map { index, dueDate in
            .object([
                "company": .string("Company \(index)"),
                "url": .string("https://example.com/company-\(index)"),
                "title": .string("Follow up with Company \(index)"),
                "due_date": .string(dueDate),
            ])
        }
        return TaskStep(
            id: "create-research-followups", description: "Create approved follow-ups",
            tool: "research.create_note_and_followups",
            arguments: [
                "task_marker": .string(marker),
                "recommendations": .array(recommendations),
                "followups": .array(followups),
                "required_headings": .array([
                    .string("Recommendations"), .string("Comparison"), .string("Sources"),
                ]),
            ],
            preconditions: [],
            postconditions: [
                Predicate(
                    id: "research-note-exists", description: "note",
                    expected: ["task_marker": .string(marker)]),
                Predicate(
                    id: "research-exactly-three", description: "three",
                    expected: ["recommendation_count": .number(3)]),
                Predicate(
                    id: "research-citations", description: "citations",
                    expected: ["source_urls": .array((1...3).map {
                        .string("https://example.com/company-\($0)")
                    })]),
                Predicate(
                    id: "research-followups", description: "followups",
                    expected: [
                        "count": .number(3),
                        "local_dates": .array(dates.map(JSONValue.string)),
                    ]),
                Predicate(
                    id: "research-visible", description: "visible",
                    expected: ["visible": .bool(true)]),
            ],
            risk: .reversibleWrite, requiresConfirmation: true,
            fallbackTools: [], maxAttempts: 1, timeoutSeconds: 60,
            verifier: VerifierSpec(kind: "composite", description: "fetch back"))
    }

    func testDraftRequiresExactlyThreeRecommendationsAndFollowups() throws {
        let draft = try ResearchFollowupDraft(step: step())

        XCTAssertEqual(draft.recommendations.count, 3)
        XCTAssertEqual(draft.followups.count, 3)
        XCTAssertEqual(draft.followups[0].dueDate, LocalDate(year: 2026, month: 7, day: 20))
    }

    func testHTMLBuilderEscapesResearchTextAndKeepsCitations() throws {
        let original = try ResearchFollowupDraft(step: step())
        var recommendations = original.recommendations
        recommendations[0] = ResearchRecommendation(
            rank: 1, name: "<script>bad</script>",
            url: recommendations[0].url,
            rationale: "A & B", summary: "<b>untrusted</b>", score: 99)
        let draft = ResearchFollowupDraft(
            stepID: original.stepID, taskMarker: original.taskMarker,
            recommendations: recommendations, followups: original.followups,
            requiredHeadings: original.requiredHeadings, predicates: original.predicates)

        let html = ResearchFollowupHTMLBuilder.build(draft: draft)

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;bad&lt;/script&gt;"))
        XCTAssertTrue(html.contains("https://example.com/company-1"))
        XCTAssertTrue(html.contains("voiceops-recommendation:1"))
    }

    func testVerifierRequiresExactlyThreeCitedRecommendationsAndMatchingDates() throws {
        let draft = try ResearchFollowupDraft(step: step())
        let note = ResearchNoteRecord(
            identifier: "note-id", title: "VoiceOps Research — Top 3 Companies",
            body: ResearchFollowupHTMLBuilder.build(draft: draft))
        let reminders = zip(draft.followups, 1...).map { followup, index in
            ResearchFollowupRecord(
                identifier: "reminder-\(index)", title: followup.title,
                company: followup.company, dueDate: followup.dueDate,
                notes: followup.url + "\n" + draft.taskMarker)
        }

        let results = ResearchFollowupVerificationEngine.verify(
            draft: draft, fetchedNote: note,
            fetchedFollowups: reminders, visiblyDisplayed: true)

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testVerifierFailsChangedFollowupDateAndMissingCitation() throws {
        let draft = try ResearchFollowupDraft(step: step())
        let body = ResearchFollowupHTMLBuilder.build(draft: draft)
            .replacingOccurrences(of: draft.recommendations[0].url, with: "missing")
        let note = ResearchNoteRecord(identifier: "note-id", title: "Research", body: body)
        let reminders = draft.followups.enumerated().map { index, followup in
            ResearchFollowupRecord(
                identifier: "reminder-\(index)", title: followup.title,
                company: followup.company,
                dueDate: index == 0 ? LocalDate(year: 2026, month: 7, day: 21) : followup.dueDate,
                notes: followup.url + "\n" + draft.taskMarker)
        }

        let results = ResearchFollowupVerificationEngine.verify(
            draft: draft, fetchedNote: note,
            fetchedFollowups: reminders, visiblyDisplayed: true)

        XCTAssertFalse(results.first { $0.predicateId == "research-citations" }!.passed)
        XCTAssertFalse(results.first { $0.predicateId == "research-followups" }!.passed)
    }

    func testVerifierAcceptsEscapedCitationTextButRejectsDuplicateRecommendationMarker() throws {
        let original = try ResearchFollowupDraft(step: step())
        var recommendations = original.recommendations
        recommendations[0] = ResearchRecommendation(
            rank: 1, name: recommendations[0].name,
            url: "https://example.com/company-1?a=1&b=2",
            rationale: "Strong R&D & delivery",
            summary: recommendations[0].summary, score: recommendations[0].score)
        let draft = ResearchFollowupDraft(
            stepID: original.stepID, taskMarker: original.taskMarker,
            recommendations: recommendations, followups: original.followups,
            requiredHeadings: original.requiredHeadings, predicates: original.predicates)
        let rendered = ResearchFollowupHTMLBuilder.build(draft: draft)
        var note = ResearchNoteRecord(
            identifier: "note-id", title: "Research", body: rendered)

        var results = ResearchFollowupVerificationEngine.verify(
            draft: draft, fetchedNote: note, fetchedFollowups: [], visiblyDisplayed: true)
        XCTAssertTrue(results.first { $0.predicateId == "research-citations" }!.passed)

        note = ResearchNoteRecord(
            identifier: note.identifier, title: note.title,
            body: rendered + " voiceops-recommendation:1")
        results = ResearchFollowupVerificationEngine.verify(
            draft: draft, fetchedNote: note, fetchedFollowups: [], visiblyDisplayed: true)
        XCTAssertFalse(results.first { $0.predicateId == "research-exactly-three" }!.passed)
    }
}
