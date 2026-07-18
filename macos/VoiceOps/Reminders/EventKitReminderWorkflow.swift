import AppKit
@preconcurrency import EventKit
import Foundation
import VoiceOpsCore
import os

private let reminderLog = Logger(
    subsystem: "com.voiceops.VoiceOps", category: "reminders")

private struct ReminderRevealResult {
    let displayed: Bool
    let settingsURL: String?
}

enum ReminderWorkflowError: Error, LocalizedError {
    case permissionDenied
    case noDefaultList
    case missingCreatedIdentifier
    case missingActionIdentifier

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Reminders access is required. Enable VoiceOps in System Settings → Privacy & Security → Reminders."
        case .noDefaultList:
            "No writable default Reminders list is configured on this Mac."
        case .missingCreatedIdentifier:
            "EventKit committed the reminder without returning an identifier."
        case .missingActionIdentifier:
            "The reminder action result did not contain an EventKit identifier."
        }
    }

    var failureCode: String {
        switch self {
        case .permissionDenied: "PERMISSION_DENIED"
        case .noDefaultList, .missingCreatedIdentifier, .missingActionIdentifier:
            "NO_STATE_CHANGE"
        }
    }

    var details: [String: JSONValue] {
        guard case .permissionDenied = self else { return [:] }
        return [
            "settings_url": .string(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        ]
    }
}

/// Native Phase 3 action channel. `execute` only reports an EventKit action
/// result. `verify` performs the independent fetch-back comparison; neither
/// method can create a task.completed message.
@MainActor
final class EventKitReminderWorkflow {
    private let eventStore = EKEventStore()

    func execute(step: TaskStep) async -> ActionResult {
        let startedAt = Date()
        do {
            let draft = try ReminderDraft(step: step)
            try await requireFullAccess()
            guard let list = eventStore.defaultCalendarForNewReminders() else {
                throw ReminderWorkflowError.noDefaultList
            }

            if let existingID = await existingReminderIdentifier(
                taskMarker: draft.taskMarker),
               let existing = eventStore.calendarItem(
                withIdentifier: existingID) as? EKReminder {
                let reveal = await showReminder(
                    identifier: existing.calendarItemIdentifier)
                reminderLog.info("reused task-marked reminder instead of duplicating it")
                return executedResult(
                    draft: draft, reminder: existing, listTitle: existing.calendar.title,
                    reveal: reveal, startedAt: startedAt, reusedExisting: true,
                    step: step)
            }

            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = list
            reminder.title = draft.title
            reminder.notes = draft.notes
            reminder.timeZone = .current
            var dueComponents = DateComponents()
            dueComponents.calendar = Calendar(identifier: .gregorian)
            dueComponents.timeZone = .current
            dueComponents.year = draft.dueDate.year
            dueComponents.month = draft.dueDate.month
            dueComponents.day = draft.dueDate.day
            reminder.dueDateComponents = dueComponents
            try eventStore.save(reminder, commit: true)

            let identifier = reminder.calendarItemIdentifier
            guard !identifier.isEmpty else {
                throw ReminderWorkflowError.missingCreatedIdentifier
            }
            let reveal = await showReminder(identifier: identifier)
            reminderLog.info(
                "committed reminder through EventKit and requested visible reveal")
            return executedResult(
                draft: draft, reminder: reminder, listTitle: list.title,
                reveal: reveal, startedAt: startedAt, reusedExisting: false,
                step: step)
        } catch {
            let workflowError = error as? ReminderWorkflowError
            reminderLog.error(
                "reminder action failed: \(error.localizedDescription, privacy: .public)")
            return ActionResult(
                stepId: step.id,
                status: .failed,
                startedAt: startedAt,
                endedAt: Date(),
                channel: "eventkit",
                targetProvenance: sourceProvenance(from: step),
                stateChangeHint: "EventKit did not confirm a committed reminder",
                error: StructuredError(
                    code: workflowError?.failureCode ?? "NO_STATE_CHANGE",
                    message: error.localizedDescription,
                    details: workflowError?.details ?? [:]))
        }
    }

    func verify(step: TaskStep, action: ActionResult) -> [VerificationResult] {
        do {
            let draft = try ReminderDraft(step: step)
            guard case .string(let identifier)? = action.rawResult["calendar_item_id"] else {
                throw ReminderWorkflowError.missingActionIdentifier
            }
            let visiblyDisplayed: Bool
            if case .bool(let value)? = action.rawResult["ui_displayed"] {
                visiblyDisplayed = value
            } else {
                visiblyDisplayed = false
            }

            // Discard EventKit's in-memory objects before resolving the committed
            // identifier. The verifier observes a fresh read, not the executor's
            // EKReminder instance.
            eventStore.reset()
            let fetched = (eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)
                .map(record)
            return ReminderVerificationEngine.verify(
                draft: draft,
                fetched: fetched,
                visiblyDisplayed: visiblyDisplayed)
        } catch {
            return step.postconditions.map { predicate in
                VerificationResult(
                    predicateId: predicate.id,
                    passed: false,
                    method: "eventkit_fetch_back",
                    confidence: 1,
                    expected: predicate.expected,
                    observed: ["error": .string(error.localizedDescription)],
                    evidenceIds: [],
                    failureReason: error.localizedDescription)
            }
        }
    }

    private func requireFullAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw ReminderWorkflowError.permissionDenied }
        case .denied, .restricted, .writeOnly:
            throw ReminderWorkflowError.permissionDenied
        @unknown default:
            throw ReminderWorkflowError.permissionDenied
        }
    }

    private func existingReminderIdentifier(taskMarker: String) async -> String? {
        let calendars = eventStore.calendars(for: .reminder)
        guard !calendars.isEmpty else { return nil }
        let predicate = eventStore.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let identifier = reminders?.first {
                    $0.notes?.contains(taskMarker) == true
                }?.calendarItemIdentifier
                continuation.resume(returning: identifier)
            }
        }
    }

    private func executedResult(
        draft: ReminderDraft,
        reminder: EKReminder,
        listTitle: String,
        reveal: ReminderRevealResult,
        startedAt: Date,
        reusedExisting: Bool,
        step: TaskStep
    ) -> ActionResult {
        var rawResult: [String: JSONValue] = [
            "calendar_item_id": .string(reminder.calendarItemIdentifier),
            "calendar_title": .string(listTitle),
            "title": .string(draft.title),
            "due_date": .string(draft.dueDate.iso8601),
            "ui_displayed": .bool(reveal.displayed),
            "reused_existing": .bool(reusedExisting),
        ]
        if let settingsURL = reveal.settingsURL {
            rawResult["settings_url"] = .string(settingsURL)
        }
        return ActionResult(
            stepId: draft.stepID,
            status: .executed,
            startedAt: startedAt,
            endedAt: Date(),
            channel: "eventkit",
            targetProvenance: sourceProvenance(from: step),
            rawResult: rawResult,
            stateChangeHint: reusedExisting
                ? "Reused the existing task-marked reminder"
                : "EventKit committed one reminder")
    }

    private func record(_ reminder: EKReminder) -> ReminderRecord {
        let components = reminder.dueDateComponents
        let dueDate: LocalDate?
        if let year = components?.year,
           let month = components?.month,
           let day = components?.day {
            dueDate = LocalDate(year: year, month: month, day: day)
        } else {
            dueDate = nil
        }
        return ReminderRecord(
            identifier: reminder.calendarItemIdentifier,
            title: reminder.title,
            dueDate: dueDate,
            notes: reminder.notes,
            calendarTitle: reminder.calendar.title)
    }

    private func showReminder(identifier: String) async -> ReminderRevealResult {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.reminders")
        else { return ReminderRevealResult(displayed: false, settingsURL: nil) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: configuration
            ) { application, error in
                continuation.resume(returning: error == nil && application != nil)
            }
        }
        guard opened else {
            return ReminderRevealResult(displayed: false, settingsURL: nil)
        }

        let safeIdentifier = identifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "com.apple.reminders"
            show reminder id "\(safeIdentifier)"
            activate
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return ReminderRevealResult(displayed: false, settingsURL: nil)
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            reminderLog.warning(
                "Reminders reveal was not verified: \(String(describing: errorInfo), privacy: .private)")
            return ReminderRevealResult(
                displayed: false,
                settingsURL:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }
        return ReminderRevealResult(displayed: true, settingsURL: nil)
    }

    private func sourceProvenance(from step: TaskStep) -> [String: JSONValue] {
        var provenance: [String: JSONValue] = [:]
        for key in ["source_app", "source_window", "source_capture_id"] {
            if let value = step.arguments[key] { provenance[key] = value }
        }
        return provenance
    }
}
