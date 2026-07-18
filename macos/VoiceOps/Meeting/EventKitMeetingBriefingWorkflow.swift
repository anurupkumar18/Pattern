import AppKit
@preconcurrency import EventKit
import Foundation
import VoiceOpsCore
import os

private let meetingLog = Logger(
    subsystem: "com.voiceops.VoiceOps", category: "meeting-briefing")

private struct NoteRevealResult {
    let displayed: Bool
    let settingsURL: String?
}

private enum MeetingWorkflowError: Error, LocalizedError {
    case calendarPermissionDenied
    case automationDenied
    case noUpcomingMeeting
    case missingEventIdentifier
    case missingActionData
    case noteScript(String)

    var errorDescription: String? {
        switch self {
        case .calendarPermissionDenied:
            "Calendar access is required. Enable VoiceOps in System Settings → Privacy & Security → Calendars."
        case .automationDenied:
            "Notes Automation access is required. Enable VoiceOps in System Settings → Privacy & Security → Automation."
        case .noUpcomingMeeting:
            "No upcoming non-all-day meeting was found in the next seven days."
        case .missingEventIdentifier:
            "EventKit returned the meeting without a stable identifier."
        case .missingActionData:
            "The meeting briefing action result is missing verification data."
        case .noteScript(let message):
            "Notes could not create the briefing: \(message)"
        }
    }

    var failureCode: String {
        switch self {
        case .calendarPermissionDenied, .automationDenied: "PERMISSION_DENIED"
        case .noUpcomingMeeting: "TARGET_NOT_FOUND"
        case .missingEventIdentifier, .missingActionData, .noteScript: "NO_STATE_CHANGE"
        }
    }

    var details: [String: JSONValue] {
        switch self {
        case .calendarPermissionDenied:
            ["settings_url": .string(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")]
        case .automationDenied:
            ["settings_url": .string(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")]
        default: [:]
        }
    }
}

/// Phase 4 hero adapter: EventKit supplies the meeting; Notes AppleScript owns
/// the reversible note write and exact UI reveal. Verification refetches both
/// stores and delegates comparisons to the pure core engine.
@MainActor
final class EventKitMeetingBriefingWorkflow {
    private let eventStore = EKEventStore()

    func execute(step: TaskStep) async -> ActionResult {
        let startedAt = Date()
        do {
            let draft = try MeetingBriefingDraft(step: step)
            try await requireCalendarAccess()
            let meeting = try nextMeeting()
            let html = MeetingBriefingHTMLBuilder.build(draft: draft, meeting: meeting)
            let noteID = try createNote(html: html)
            let reveal = revealNote(identifier: noteID)
            var raw = encode(meeting: meeting)
            raw["note_id"] = .string(noteID)
            raw["ui_displayed"] = .bool(reveal.displayed)
            if let settingsURL = reveal.settingsURL {
                raw["settings_url"] = .string(settingsURL)
            }
            meetingLog.info("created and requested reveal of one meeting briefing note")
            return ActionResult(
                stepId: draft.stepID,
                status: .executed,
                startedAt: startedAt,
                endedAt: Date(),
                channel: "eventkit+notes_applescript",
                targetProvenance: sourceProvenance(from: step),
                rawResult: raw,
                stateChangeHint: "Created one Apple Note for the selected EventKit meeting")
        } catch {
            let workflowError = error as? MeetingWorkflowError
            meetingLog.error(
                "meeting briefing action failed: \(error.localizedDescription, privacy: .public)")
            return ActionResult(
                stepId: step.id,
                status: workflowError == nil ? .uncertain : .failed,
                startedAt: startedAt,
                endedAt: Date(),
                channel: "eventkit+notes_applescript",
                targetProvenance: sourceProvenance(from: step),
                stateChangeHint: "The meeting briefing write did not complete cleanly",
                error: StructuredError(
                    code: workflowError?.failureCode ?? "CONSEQUENTIAL_STATE_UNCERTAIN",
                    message: error.localizedDescription,
                    details: workflowError?.details ?? [:]))
        }
    }

    func verify(step: TaskStep, action: ActionResult) -> [VerificationResult] {
        do {
            let draft = try MeetingBriefingDraft(step: step)
            let selected = try decodeMeeting(from: action.rawResult)
            guard case .string(let noteID)? = action.rawResult["note_id"] else {
                throw MeetingWorkflowError.missingActionData
            }
            let visiblyDisplayed: Bool
            if case .bool(let value)? = action.rawResult["ui_displayed"] {
                visiblyDisplayed = value
            } else {
                visiblyDisplayed = false
            }

            eventStore.reset()
            let fetchedMeeting = eventStore.event(withIdentifier: selected.identifier)
                .flatMap(meetingRecord)
            let fetchedNote = try fetchNote(identifier: noteID)
            return MeetingBriefingVerificationEngine.verify(
                draft: draft,
                selectedMeeting: selected,
                fetchedMeeting: fetchedMeeting,
                fetchedNote: fetchedNote,
                visiblyDisplayed: visiblyDisplayed)
        } catch {
            return step.postconditions.map { predicate in
                VerificationResult(
                    predicateId: predicate.id,
                    passed: false,
                    method: "eventkit_notes_fetch_back",
                    confidence: 1,
                    expected: predicate.expected,
                    observed: ["error": .string(error.localizedDescription)],
                    evidenceIds: [],
                    failureReason: error.localizedDescription)
            }
        }
    }

    private func requireCalendarAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw MeetingWorkflowError.calendarPermissionDenied }
        case .denied, .restricted, .writeOnly:
            throw MeetingWorkflowError.calendarPermissionDenied
        @unknown default:
            throw MeetingWorkflowError.calendarPermissionDenied
        }
    }

    private func nextMeeting() throws -> MeetingRecord {
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) else {
            throw MeetingWorkflowError.noUpcomingMeeting
        }
        let predicate = eventStore.predicateForEvents(
            withStart: now, end: horizon, calendars: nil)
        guard let event = eventStore.events(matching: predicate)
            .filter({ !$0.isAllDay && $0.endDate > now })
            .sorted(by: { $0.startDate < $1.startDate })
            .first
        else { throw MeetingWorkflowError.noUpcomingMeeting }
        guard let record = meetingRecord(event) else {
            throw MeetingWorkflowError.missingEventIdentifier
        }
        return record
    }

    private func meetingRecord(_ event: EKEvent) -> MeetingRecord? {
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let iso = ISO8601DateFormatter().string(from: event.startDate)
        return MeetingRecord(
            identifier: identifier,
            title: event.title ?? "Untitled meeting",
            startISO8601: iso,
            startDescription: formatter.string(from: event.startDate),
            attendeeNames: event.attendees?.compactMap(\.name) ?? [],
            url: event.url?.absoluteString)
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
              let result = script.executeAndReturnError(&errorInfo).stringValue,
              !result.isEmpty
        else {
            if isAuthorizationError(errorInfo) {
                throw MeetingWorkflowError.automationDenied
            }
            throw MeetingWorkflowError.noteScript(scriptMessage(errorInfo))
        }
        return result
    }

    private func revealNote(identifier: String) -> NoteRevealResult {
        let source = """
        tell application id "com.apple.Notes"
            show note id "\(appleScriptEscape(identifier))"
            activate
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return NoteRevealResult(displayed: false, settingsURL: nil)
        }
        _ = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return NoteRevealResult(
                displayed: false,
                settingsURL: isAuthorizationError(errorInfo)
                    ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                    : nil)
        }
        return NoteRevealResult(displayed: true, settingsURL: nil)
    }

    private func fetchNote(identifier: String) throws -> MeetingBriefingNoteRecord? {
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
            if isAuthorizationError(errorInfo) {
                throw MeetingWorkflowError.automationDenied
            }
            throw MeetingWorkflowError.noteScript(scriptMessage(errorInfo))
        }
        guard let value = descriptor.stringValue, !value.isEmpty else { return nil }
        let parts = value.split(separator: Character(delimiter), maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return MeetingBriefingNoteRecord(
            identifier: identifier,
            title: String(parts[0]),
            body: String(parts[1]))
    }

    private func encode(meeting: MeetingRecord) -> [String: JSONValue] {
        [
            "meeting_id": .string(meeting.identifier),
            "meeting_title": .string(meeting.title),
            "meeting_start_iso": .string(meeting.startISO8601),
            "meeting_start_description": .string(meeting.startDescription),
            "meeting_attendees": .array(meeting.attendeeNames.map(JSONValue.string)),
            "meeting_url": meeting.url.map(JSONValue.string) ?? .null,
        ]
    }

    private func decodeMeeting(
        from raw: [String: JSONValue]
    ) throws -> MeetingRecord {
        func string(_ key: String) throws -> String {
            guard case .string(let value)? = raw[key] else {
                throw MeetingWorkflowError.missingActionData
            }
            return value
        }
        let attendees: [String]
        if case .array(let values)? = raw["meeting_attendees"] {
            attendees = values.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            }
        } else {
            attendees = []
        }
        let url: String?
        if case .string(let value)? = raw["meeting_url"] { url = value } else { url = nil }
        return MeetingRecord(
            identifier: try string("meeting_id"),
            title: try string("meeting_title"),
            startISO8601: try string("meeting_start_iso"),
            startDescription: try string("meeting_start_description"),
            attendeeNames: attendees,
            url: url)
    }

    private func sourceProvenance(from step: TaskStep) -> [String: JSONValue] {
        var provenance: [String: JSONValue] = [:]
        for key in ["source_app", "source_window", "source_capture_id"] {
            if let value = step.arguments[key] { provenance[key] = value }
        }
        return provenance
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isAuthorizationError(_ info: NSDictionary?) -> Bool {
        (info?["NSAppleScriptErrorNumber"] as? Int) == -1743
    }

    private func scriptMessage(_ info: NSDictionary?) -> String {
        (info?["NSAppleScriptErrorMessage"] as? String) ?? "unknown scripting error"
    }
}
