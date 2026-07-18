import Foundation

public enum MeetingBriefingDraftError: Error, LocalizedError {
    case wrongTool(String)
    case missingArgument(String)

    public var errorDescription: String? {
        switch self {
        case .wrongTool(let tool): "Unsupported meeting briefing tool: \(tool)."
        case .missingArgument(let name): "Meeting briefing plan is missing \(name)."
        }
    }
}

public struct MeetingBriefingDraft: Equatable, Sendable {
    public let stepID: String
    public let taskMarker: String
    public let requiredHeadings: [String]
    public let visibleContext: String
    public let predicates: [Predicate]

    public init(
        stepID: String,
        taskMarker: String,
        requiredHeadings: [String],
        visibleContext: String,
        predicates: [Predicate]
    ) {
        self.stepID = stepID
        self.taskMarker = taskMarker
        self.requiredHeadings = requiredHeadings
        self.visibleContext = visibleContext
        self.predicates = predicates
    }

    public init(step: TaskStep) throws {
        guard step.tool == "notes.create_meeting_brief" else {
            throw MeetingBriefingDraftError.wrongTool(step.tool)
        }
        stepID = step.id
        taskMarker = try Self.requiredString("task_marker", arguments: step.arguments)
        visibleContext = try Self.requiredString("visible_context", arguments: step.arguments)
        guard case .array(let headingValues)? = step.arguments["required_headings"] else {
            throw MeetingBriefingDraftError.missingArgument("required_headings")
        }
        requiredHeadings = headingValues.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
        guard !requiredHeadings.isEmpty else {
            throw MeetingBriefingDraftError.missingArgument("required_headings")
        }
        predicates = step.postconditions
    }

    private static func requiredString(
        _ key: String, arguments: [String: JSONValue]
    ) throws -> String {
        guard case .string(let value)? = arguments[key], !value.isEmpty else {
            throw MeetingBriefingDraftError.missingArgument(key)
        }
        return value
    }
}

/// Builds Notes HTML from untrusted observed text. Every dynamic field is
/// escaped before it enters markup, so screen content remains data rather than
/// executable or formatting instructions.
public enum MeetingBriefingHTMLBuilder {
    public static func build(
        draft: MeetingBriefingDraft, meeting: MeetingRecord
    ) -> String {
        let participants = meeting.attendeeNames.isEmpty
            ? "No attendee names available"
            : meeting.attendeeNames.joined(separator: ", ")
        let link: String
        if let url = meeting.url {
            let safe = escape(url)
            link = "<p><a href=\"\(safe)\">\(safe)</a></p>"
        } else {
            link = "<p>No meeting link available</p>"
        }
        let context = escape(draft.visibleContext)
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <h1>VoiceOps Brief — \(escape(meeting.title))</h1>
        <h2>Meeting</h2>
        <p><b>\(escape(meeting.title))</b><br>\(escape(meeting.startDescription))</p>
        \(link)
        <h2>Participants</h2>
        <p>\(escape(participants))</p>
        <h2>Context</h2>
        <p>\(context)</p>
        <h2>Open Questions</h2>
        <ul><li>What decision or outcome matters most for this meeting?</li><li>Which visible context needs confirmation?</li></ul>
        <h2>Sources</h2>
        <ul><li>EventKit event: \(escape(meeting.identifier))</li><li>Task-scoped active-screen observation</li></ul>
        <p>voiceops-event:\(escape(meeting.identifier))</p>
        <p>\(escape(draft.taskMarker))</p>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

public struct MeetingRecord: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let startISO8601: String
    public let startDescription: String
    public let attendeeNames: [String]
    public let url: String?

    public init(
        identifier: String,
        title: String,
        startISO8601: String,
        startDescription: String,
        attendeeNames: [String],
        url: String?
    ) {
        self.identifier = identifier
        self.title = title
        self.startISO8601 = startISO8601
        self.startDescription = startDescription
        self.attendeeNames = attendeeNames
        self.url = url
    }
}

public struct MeetingBriefingNoteRecord: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public enum MeetingBriefingVerificationEngine {
    public static func verify(
        draft: MeetingBriefingDraft,
        selectedMeeting: MeetingRecord?,
        fetchedMeeting: MeetingRecord?,
        fetchedNote: MeetingBriefingNoteRecord?,
        visiblyDisplayed: Bool
    ) -> [VerificationResult] {
        var evidence: [String] = []
        if let fetchedMeeting { evidence.append("eventkit:\(fetchedMeeting.identifier)") }
        if let fetchedNote { evidence.append("notes:\(fetchedNote.identifier)") }

        return draft.predicates.map { predicate in
            let evaluation = evaluate(
                predicate,
                draft: draft,
                selectedMeeting: selectedMeeting,
                fetchedMeeting: fetchedMeeting,
                fetchedNote: fetchedNote,
                visiblyDisplayed: visiblyDisplayed)
            return VerificationResult(
                predicateId: predicate.id,
                passed: evaluation.passed,
                method: predicate.id == "brief-visible"
                    ? "notes_ui" : "eventkit_notes_fetch_back",
                confidence: predicate.id == "brief-visible" ? 0.95 : 1,
                expected: predicate.expected,
                observed: evaluation.observed,
                evidenceIds: evidence,
                failureReason: evaluation.passed ? nil : evaluation.reason)
        }
    }

    private static func evaluate(
        _ predicate: Predicate,
        draft: MeetingBriefingDraft,
        selectedMeeting: MeetingRecord?,
        fetchedMeeting: MeetingRecord?,
        fetchedNote: MeetingBriefingNoteRecord?,
        visiblyDisplayed: Bool
    ) -> (passed: Bool, observed: [String: JSONValue], reason: String) {
        switch predicate.id {
        case "meeting-selected":
            let stable = selectedMeeting != nil && fetchedMeeting != nil
                && selectedMeeting?.identifier == fetchedMeeting?.identifier
                && selectedMeeting?.title == fetchedMeeting?.title
                && selectedMeeting?.startISO8601 == fetchedMeeting?.startISO8601
            return (
                stable,
                [
                    "selected_event_id": selectedMeeting.map {
                        .string($0.identifier)
                    } ?? .null,
                    "fetched_event_id": fetchedMeeting.map {
                        .string($0.identifier)
                    } ?? .null,
                    "unchanged": .bool(stable),
                ],
                "The selected next meeting could not be fetched unchanged.")

        case "brief-exists":
            let markerPresent = fetchedNote?.body.contains(draft.taskMarker) == true
            return (
                fetchedNote != nil && markerPresent,
                [
                    "note_id": fetchedNote.map { .string($0.identifier) } ?? .null,
                    "task_marker_present": .bool(markerPresent),
                ],
                "The created note could not be fetched with its task marker.")

        case "brief-headings":
            let body = fetchedNote?.body ?? ""
            let matched = draft.requiredHeadings.filter(body.contains)
            let passed = matched.count == draft.requiredHeadings.count
            return (
                passed,
                ["matched_headings": .array(matched.map(JSONValue.string))],
                "The fetched note is missing one or more required headings.")

        case "brief-meeting-identity":
            guard let selectedMeeting else {
                return (false, ["meeting": .null], "No selected meeting was recorded.")
            }
            let body = fetchedNote?.body ?? ""
            let fields = [
                selectedMeeting.title,
                selectedMeeting.startDescription,
                "voiceops-event:\(selectedMeeting.identifier)",
            ]
            let matched = fields.filter(body.contains)
            return (
                matched.count == fields.count,
                ["matched_fields": .array(matched.map(JSONValue.string))],
                "The note did not retain the selected meeting title, time, and identifier.")

        case "brief-visible":
            return (
                visiblyDisplayed,
                ["visible": .bool(visiblyDisplayed)],
                "The note exists, but VoiceOps could not show it in Notes.")

        default:
            return (
                false,
                ["unsupported_predicate": .string(predicate.id)],
                "The verifier does not implement this predicate.")
        }
    }
}
