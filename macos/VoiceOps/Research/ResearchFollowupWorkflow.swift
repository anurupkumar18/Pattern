import AppKit
@preconcurrency import EventKit
import Foundation
import VoiceOpsCore
import os

private let researchLog = Logger(
    subsystem: "com.voiceops.VoiceOps", category: "research-followup")

private struct ResearchRevealResult {
    let displayed: Bool
    let settingsURL: String?
}

private enum ResearchWorkflowError: Error, LocalizedError {
    case remindersPermissionDenied
    case automationDenied
    case noDefaultList
    case missingReminderIdentifier
    case missingActionData
    case notes(String)
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .remindersPermissionDenied:
            "Reminders access is required before approved follow-ups can be created."
        case .automationDenied:
            "Notes Automation access is required before the comparison note can be created."
        case .noDefaultList:
            "No writable default Reminders list is configured on this Mac."
        case .missingReminderIdentifier:
            "EventKit committed a follow-up without returning an identifier."
        case .missingActionData:
            "The research action result is missing verification data."
        case .notes(let message):
            "Notes could not complete the comparison artifact: \(message)"
        case .rollbackFailed:
            "A partial research write could not be rolled back safely."
        }
    }

    var failureCode: String {
        switch self {
        case .remindersPermissionDenied, .automationDenied: "PERMISSION_DENIED"
        case .rollbackFailed: "CONSEQUENTIAL_STATE_UNCERTAIN"
        default: "NO_STATE_CHANGE"
        }
    }

    var details: [String: JSONValue] {
        switch self {
        case .remindersPermissionDenied:
            ["settings_url": .string(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")]
        case .automationDenied:
            ["settings_url": .string(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")]
        default: [:]
        }
    }
}

/// Approval is handled by AppCoordinator before this adapter is called. This
/// executor performs the approved local writes once, rolls back task-scoped
/// Notes and Reminders artifacts on failure, and leaves overall success to the
/// fetch-back verifier.
@MainActor
final class ResearchFollowupWorkflow {
    private let eventStore = EKEventStore()

    func execute(step: TaskStep) async -> ActionResult {
        let startedAt = Date()
        var createdReminders: [EKReminder] = []
        var taskMarker: String?
        do {
            let draft = try ResearchFollowupDraft(step: step)
            taskMarker = draft.taskMarker
            try await requireRemindersAccess()
            try preflightNotesAccess()
            guard let list = eventStore.defaultCalendarForNewReminders() else {
                throw ResearchWorkflowError.noDefaultList
            }

            for followup in draft.followups {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = list
                reminder.title = followup.title
                reminder.notes = [
                    "Company: \(followup.company)",
                    "Source: \(followup.url)",
                    draft.taskMarker,
                ].joined(separator: "\n")
                reminder.timeZone = .current
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = .current
                components.year = followup.dueDate.year
                components.month = followup.dueDate.month
                components.day = followup.dueDate.day
                reminder.dueDateComponents = components
                try eventStore.save(reminder, commit: true)
                guard !reminder.calendarItemIdentifier.isEmpty else {
                    throw ResearchWorkflowError.missingReminderIdentifier
                }
                createdReminders.append(reminder)
            }

            let html = ResearchFollowupHTMLBuilder.build(draft: draft)
            let noteID = try createNote(html: html)
            let reveal = revealNote(identifier: noteID)
            var raw: [String: JSONValue] = [
                "note_id": .string(noteID),
                "reminder_ids": .array(createdReminders.map {
                    .string($0.calendarItemIdentifier)
                }),
                "ui_displayed": .bool(reveal.displayed),
            ]
            if let settingsURL = reveal.settingsURL {
                raw["settings_url"] = .string(settingsURL)
            }
            researchLog.info("created one research note and three approved follow-ups")
            return ActionResult(
                stepId: draft.stepID, status: .executed,
                startedAt: startedAt, endedAt: Date(),
                channel: "notes_applescript+eventkit",
                targetProvenance: sourceProvenance(from: step),
                rawResult: raw,
                stateChangeHint: "Created one comparison note and three approved reminders")
        } catch {
            let remindersRollbackSucceeded = rollback(createdReminders)
            let notesRollbackSucceeded = taskMarker.map(rollbackNotes) ?? true
            let rollbackSucceeded = remindersRollbackSucceeded && notesRollbackSucceeded
            let workflowError: ResearchWorkflowError
            if !rollbackSucceeded {
                workflowError = .rollbackFailed
            } else if let known = error as? ResearchWorkflowError {
                workflowError = known
            } else {
                workflowError = .notes(error.localizedDescription)
            }
            researchLog.error(
                "research workflow action failed: \(workflowError.localizedDescription, privacy: .public)")
            return ActionResult(
                stepId: step.id,
                status: rollbackSucceeded ? .failed : .uncertain,
                startedAt: startedAt, endedAt: Date(),
                channel: "notes_applescript+eventkit",
                targetProvenance: sourceProvenance(from: step),
                stateChangeHint: rollbackSucceeded
                    ? "No task-scoped note or approved reminders remain after rollback"
                    : "A partial research write may remain; VoiceOps will not retry",
                error: StructuredError(
                    code: workflowError.failureCode,
                    message: workflowError.localizedDescription,
                    details: workflowError.details))
        }
    }

    func verify(step: TaskStep, action: ActionResult) -> [VerificationResult] {
        do {
            let draft = try ResearchFollowupDraft(step: step)
            guard case .string(let noteID)? = action.rawResult["note_id"],
                  case .array(let rawIDs)? = action.rawResult["reminder_ids"]
            else { throw ResearchWorkflowError.missingActionData }
            let reminderIDs = rawIDs.compactMap { value -> String? in
                guard case .string(let identifier) = value else { return nil }
                return identifier
            }
            guard reminderIDs.count == draft.followups.count else {
                throw ResearchWorkflowError.missingActionData
            }
            let visiblyDisplayed: Bool
            if case .bool(let value)? = action.rawResult["ui_displayed"] {
                visiblyDisplayed = value
            } else {
                visiblyDisplayed = false
            }

            eventStore.reset()
            let records = zip(draft.followups, reminderIDs).compactMap {
                expected, identifier -> ResearchFollowupRecord? in
                guard let reminder = eventStore.calendarItem(
                    withIdentifier: identifier) as? EKReminder
                else { return nil }
                let components = reminder.dueDateComponents
                let dueDate: LocalDate?
                if let year = components?.year,
                   let month = components?.month,
                   let day = components?.day {
                    dueDate = LocalDate(year: year, month: month, day: day)
                } else {
                    dueDate = nil
                }
                return ResearchFollowupRecord(
                    identifier: identifier,
                    title: reminder.title,
                    company: expected.company,
                    dueDate: dueDate,
                    notes: reminder.notes)
            }
            let note = try fetchNote(identifier: noteID)
            return ResearchFollowupVerificationEngine.verify(
                draft: draft, fetchedNote: note,
                fetchedFollowups: records, visiblyDisplayed: visiblyDisplayed)
        } catch {
            return step.postconditions.map { predicate in
                VerificationResult(
                    predicateId: predicate.id, passed: false,
                    method: "notes_eventkit_fetch_back", confidence: 1,
                    expected: predicate.expected,
                    observed: ["error": .string(error.localizedDescription)],
                    evidenceIds: [], failureReason: error.localizedDescription)
            }
        }
    }

    private func requireRemindersAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else { throw ResearchWorkflowError.remindersPermissionDenied }
        case .denied, .restricted, .writeOnly:
            throw ResearchWorkflowError.remindersPermissionDenied
        @unknown default:
            throw ResearchWorkflowError.remindersPermissionDenied
        }
    }

    private func preflightNotesAccess() throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(
            source: "tell application id \"com.apple.Notes\" to count accounts")
        else { throw ResearchWorkflowError.notes("could not compile access check") }
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if isAuthorizationError(errorInfo) {
                throw ResearchWorkflowError.automationDenied
            }
            throw ResearchWorkflowError.notes(scriptMessage(errorInfo))
        }
    }

    private func createNote(html: String) throws -> String {
        let encoded = Data(html.utf8).base64EncodedString()
        let source = """
        set encodedBody to "\(encoded)"
        set noteBody to do shell script "/bin/echo " & quoted form of encodedBody & " | /usr/bin/base64 -D"
        tell application id "com.apple.Notes"
            set createdNote to make new note at default folder with properties {body:noteBody}
            return id of createdNote
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let identifier = script.executeAndReturnError(&errorInfo).stringValue,
              !identifier.isEmpty
        else {
            if isAuthorizationError(errorInfo) {
                throw ResearchWorkflowError.automationDenied
            }
            throw ResearchWorkflowError.notes(scriptMessage(errorInfo))
        }
        return identifier
    }

    private func revealNote(identifier: String) -> ResearchRevealResult {
        let source = """
        tell application id "com.apple.Notes"
            show note id "\(appleScriptEscape(identifier))"
            activate
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ResearchRevealResult(displayed: false, settingsURL: nil)
        }
        _ = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return ResearchRevealResult(
                displayed: false,
                settingsURL: isAuthorizationError(errorInfo)
                    ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                    : nil)
        }
        return ResearchRevealResult(displayed: true, settingsURL: nil)
    }

    private func fetchNote(identifier: String) throws -> ResearchNoteRecord? {
        let delimiter = String(UnicodeScalar(30))
        let source = """
        tell application id "com.apple.Notes"
            set matchingNotes to every note whose id is "\(appleScriptEscape(identifier))"
            if (count of matchingNotes) is 0 then return ""
            set fetchedNote to item 1 of matchingNotes
            return (name of fetchedNote) & ASCII character 30 & (body of fetchedNote)
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if isAuthorizationError(errorInfo) { throw ResearchWorkflowError.automationDenied }
            throw ResearchWorkflowError.notes(scriptMessage(errorInfo))
        }
        guard let value = descriptor.stringValue, !value.isEmpty else { return nil }
        let parts = value.split(separator: Character(delimiter), maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return ResearchNoteRecord(
            identifier: identifier, title: String(parts[0]), body: String(parts[1]))
    }

    private func rollback(_ reminders: [EKReminder]) -> Bool {
        var succeeded = true
        for reminder in reminders {
            do { try eventStore.remove(reminder, commit: true) }
            catch { succeeded = false }
        }
        return succeeded
    }

    private func rollbackNotes(containing taskMarker: String) -> Bool {
        let source = """
        tell application id "com.apple.Notes"
            set matchingNotes to every note whose body contains "\(appleScriptEscape(taskMarker))"
            repeat with matchingNote in matchingNotes
                delete matchingNote
            end repeat
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    private func sourceProvenance(from step: TaskStep) -> [String: JSONValue] {
        var provenance: [String: JSONValue] = [:]
        for key in ["source_app", "source_window", "source_capture_id"] {
            if let value = step.arguments[key] { provenance[key] = value }
        }
        return provenance
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isAuthorizationError(_ info: NSDictionary?) -> Bool {
        (info?["NSAppleScriptErrorNumber"] as? Int) == -1743
    }

    private func scriptMessage(_ info: NSDictionary?) -> String {
        (info?["NSAppleScriptErrorMessage"] as? String) ?? "unknown scripting error"
    }
}
