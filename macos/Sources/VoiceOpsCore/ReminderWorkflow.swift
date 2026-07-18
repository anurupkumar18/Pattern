import Foundation

public struct LocalDate: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(iso8601: String) throws {
        let parts = iso8601.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { throw ReminderDraftError.invalidDueDate(iso8601) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components
        else { throw ReminderDraftError.invalidDueDate(iso8601) }
        self.init(year: year, month: month, day: day)
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

public struct LocalTime: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init(hhmm: String) throws {
        let parts = hhmm.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { throw ReminderDraftError.invalidDueTime(hhmm) }
        self.init(hour: hour, minute: minute)
    }

    public var hhmm: String { String(format: "%02d:%02d", hour, minute) }
}

public enum ReminderDraftError: Error, Equatable, LocalizedError {
    case wrongTool(String)
    case missingArgument(String)
    case invalidDueDate(String)
    case invalidDueTime(String)

    public var errorDescription: String? {
        switch self {
        case .wrongTool(let tool): "Unsupported reminder tool: \(tool)."
        case .missingArgument(let name): "Reminder plan is missing \(name)."
        case .invalidDueDate(let value): "Reminder due date is invalid: \(value)."
        case .invalidDueTime(let value): "Reminder due time is invalid: \(value)."
        }
    }
}

public struct ReminderDraft: Equatable, Sendable {
    public let stepID: String
    public let title: String
    public let dueDate: LocalDate
    public let dueTime: LocalTime?
    public let notes: String
    public let taskMarker: String
    public let predicates: [Predicate]

    public init(step: TaskStep) throws {
        guard step.tool == "reminders.create" else {
            throw ReminderDraftError.wrongTool(step.tool)
        }
        stepID = step.id
        title = try Self.requiredString("title", in: step.arguments)
        dueDate = try LocalDate(
            iso8601: Self.requiredString("due_date", in: step.arguments))
        if case .string(let value)? = step.arguments["due_time"] {
            dueTime = try LocalTime(hhmm: value)
        } else {
            dueTime = nil
        }
        notes = try Self.requiredString("notes", in: step.arguments)
        taskMarker = try Self.requiredString("task_marker", in: step.arguments)
        predicates = step.postconditions
    }

    private static func requiredString(
        _ key: String, in arguments: [String: JSONValue]
    ) throws -> String {
        guard case .string(let value)? = arguments[key], !value.isEmpty else {
            throw ReminderDraftError.missingArgument(key)
        }
        return value
    }
}

public struct ReminderRecord: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let dueDate: LocalDate?
    public let dueTime: LocalTime?
    public let notes: String?
    public let calendarTitle: String

    public init(
        identifier: String,
        title: String,
        dueDate: LocalDate?,
        dueTime: LocalTime? = nil,
        notes: String?,
        calendarTitle: String
    ) {
        self.identifier = identifier
        self.title = title
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.notes = notes
        self.calendarTitle = calendarTitle
    }
}

/// Pure comparison engine. It never creates data and therefore cannot confuse
/// an executor return value with verified task success.
public enum ReminderVerificationEngine {
    public static func verify(
        draft: ReminderDraft,
        fetched: ReminderRecord?,
        visiblyDisplayed: Bool
    ) -> [VerificationResult] {
        let evidence = fetched.map { ["eventkit:\($0.identifier)"] } ?? []
        return draft.predicates.map { predicate in
            let evaluation = evaluate(
                predicate, draft: draft, fetched: fetched,
                visiblyDisplayed: visiblyDisplayed)
            return VerificationResult(
                predicateId: predicate.id,
                passed: evaluation.passed,
                method: predicate.id == "reminder-visible"
                    ? "reminders_ui" : "eventkit_fetch_back",
                confidence: predicate.id == "reminder-visible" ? 0.95 : 1,
                expected: predicate.expected,
                observed: evaluation.observed,
                evidenceIds: evidence,
                failureReason: evaluation.passed ? nil : evaluation.failureReason)
        }
    }

    private static func evaluate(
        _ predicate: Predicate,
        draft: ReminderDraft,
        fetched: ReminderRecord?,
        visiblyDisplayed: Bool
    ) -> (passed: Bool, observed: [String: JSONValue], failureReason: String) {
        switch predicate.id {
        case "reminder-exists":
            let markerPresent = fetched?.notes?.contains(draft.taskMarker) == true
            return (
                fetched != nil && markerPresent,
                [
                    "calendar_item_id": fetched.map { .string($0.identifier) } ?? .null,
                    "task_marker_present": .bool(markerPresent),
                ],
                "The committed reminder could not be fetched with its task marker.")

        case "reminder-title":
            let passed = fetched?.title.localizedCaseInsensitiveContains(draft.title) == true
            return (
                passed,
                ["title": fetched.map { .string($0.title) } ?? .null],
                "The fetched reminder title did not contain the visible commitment.")

        case "reminder-due-date":
            let expectedTime = predicate.expected["local_time"]
            let timePassed: Bool
            if case .string(let value)? = expectedTime {
                timePassed = fetched?.dueTime?.hhmm == value
            } else {
                timePassed = true
            }
            let passed = fetched?.dueDate == draft.dueDate && timePassed
            return (
                passed,
                [
                    "local_date": fetched?.dueDate.map { .string($0.iso8601) } ?? .null,
                    "local_time": fetched?.dueTime.map { .string($0.hhmm) } ?? .null,
                ],
                "The fetched reminder due date or time did not match the plan.")

        case "reminder-notes":
            let required = predicate.expected["contains"]?.stringArray ?? []
            let notes = fetched?.notes ?? ""
            let matched = required.filter(notes.contains)
            let passed = !required.isEmpty && matched.count == required.count
            return (
                passed,
                [
                    "required": .array(required.map(JSONValue.string)),
                    "matched": .array(matched.map(JSONValue.string)),
                ],
                "The fetched reminder notes did not retain all source context.")

        case "reminder-visible":
            return (
                visiblyDisplayed,
                ["visible": .bool(visiblyDisplayed)],
                "The reminder exists, but VoiceOps could not show it in Reminders.")

        default:
            return (
                false,
                ["unsupported_predicate": .string(predicate.id)],
                "The verifier does not implement this predicate.")
        }
    }
}

private extension JSONValue {
    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }
}
