import XCTest
@testable import VoiceOpsCore

final class ReminderWorkflowTests: XCTestCase {
    private func planStep() -> TaskStep {
        let marker = "voiceops-task:b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d"
        return TaskStep(
            id: "create-screen-reminder",
            description: "Create reminder",
            tool: "reminders.create",
            arguments: [
                "title": .string("Hackathon deadline details"),
                "due_date": .string("2026-07-29"),
                "deadline_date": .string("2026-07-31"),
                "notes": .string("Source: Mail — Hackathon details\n" + marker),
                "task_marker": .string(marker),
            ],
            preconditions: [],
            postconditions: [
                Predicate(
                    id: "reminder-exists", description: "exists",
                    expected: ["task_marker": .string(marker)]),
                Predicate(
                    id: "reminder-title", description: "title",
                    expected: ["contains": .string("Hackathon deadline details")]),
                Predicate(
                    id: "reminder-due-date", description: "due",
                    expected: ["local_date": .string("2026-07-29")]),
                Predicate(
                    id: "reminder-notes", description: "notes",
                    expected: ["contains": .array([
                        .string("Source: Mail — Hackathon details"), .string(marker),
                    ])]),
                Predicate(
                    id: "reminder-visible", description: "visible",
                    expected: ["visible": .bool(true)]),
            ],
            risk: .reversibleWrite,
            requiresConfirmation: false,
            fallbackTools: [],
            maxAttempts: 1,
            timeoutSeconds: 30,
            verifier: VerifierSpec(kind: "composite", description: "fetch and show"))
    }

    func testDraftRequiresTypedReminderArguments() throws {
        let draft = try ReminderDraft(step: planStep())

        XCTAssertEqual(draft.title, "Hackathon deadline details")
        XCTAssertEqual(draft.dueDate, LocalDate(year: 2026, month: 7, day: 29))
        XCTAssertTrue(draft.notes.contains(draft.taskMarker))
    }

    func testDraftRejectsInvalidDueDate() {
        let original = planStep()
        let invalid = TaskStep(
            id: original.id, description: original.description, tool: original.tool,
            arguments: original.arguments.merging(["due_date": .string("July soon")]) { _, new in new },
            preconditions: original.preconditions, postconditions: original.postconditions,
            risk: original.risk, requiresConfirmation: original.requiresConfirmation,
            fallbackTools: original.fallbackTools, maxAttempts: original.maxAttempts,
            timeoutSeconds: original.timeoutSeconds, verifier: original.verifier)

        XCTAssertThrowsError(try ReminderDraft(step: invalid))
    }

    func testVerifierPassesOnlyWhenFetchedFieldsAndVisibilityMatch() throws {
        let draft = try ReminderDraft(step: planStep())
        let record = ReminderRecord(
            identifier: "eventkit-id",
            title: "Hackathon deadline details",
            dueDate: LocalDate(year: 2026, month: 7, day: 29),
            notes: draft.notes,
            calendarTitle: "Reminders")

        let results = ReminderVerificationEngine.verify(
            draft: draft, fetched: record, visiblyDisplayed: true)

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy(\.passed))
        XCTAssertEqual(Set(results.map(\.predicateId)), Set(draft.predicates.map(\.id)))
        XCTAssertTrue(results.allSatisfy { $0.evidenceIds == ["eventkit:eventkit-id"] })
    }

    func testVerifierReportsWrongDateAndHiddenUIWithoutFalseSuccess() throws {
        let draft = try ReminderDraft(step: planStep())
        let record = ReminderRecord(
            identifier: "eventkit-id",
            title: draft.title,
            dueDate: LocalDate(year: 2026, month: 7, day: 30),
            notes: draft.notes,
            calendarTitle: "Reminders")

        let results = ReminderVerificationEngine.verify(
            draft: draft, fetched: record, visiblyDisplayed: false)

        XCTAssertFalse(results.first { $0.predicateId == "reminder-due-date" }!.passed)
        XCTAssertFalse(results.first { $0.predicateId == "reminder-visible" }!.passed)
        XCTAssertFalse(results.allSatisfy(\.passed))
    }
}
