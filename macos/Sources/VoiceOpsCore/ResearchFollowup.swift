import Foundation

public struct ResearchRecommendation: Equatable, Sendable {
    public let rank: Int
    public let name: String
    public let url: String
    public let rationale: String
    public let summary: String
    public let score: Int

    public init(
        rank: Int, name: String, url: String, rationale: String,
        summary: String, score: Int
    ) {
        self.rank = rank
        self.name = name
        self.url = url
        self.rationale = rationale
        self.summary = summary
        self.score = score
    }
}

public struct ResearchFollowup: Equatable, Sendable {
    public let company: String
    public let url: String
    public let title: String
    public let dueDate: LocalDate

    public init(company: String, url: String, title: String, dueDate: LocalDate) {
        self.company = company
        self.url = url
        self.title = title
        self.dueDate = dueDate
    }
}

public enum ResearchFollowupDraftError: Error, LocalizedError {
    case wrongTool(String)
    case missingArgument(String)
    case requiresExactlyThree

    public var errorDescription: String? {
        switch self {
        case .wrongTool(let tool): "Unsupported research tool: \(tool)."
        case .missingArgument(let name): "Research plan is missing \(name)."
        case .requiresExactlyThree:
            "Research-to-Follow-Up requires exactly three recommendations and follow-ups."
        }
    }
}

public struct ResearchFollowupDraft: Equatable, Sendable {
    public let stepID: String
    public let taskMarker: String
    public let recommendations: [ResearchRecommendation]
    public let followups: [ResearchFollowup]
    public let requiredHeadings: [String]
    public let predicates: [Predicate]

    public init(
        stepID: String, taskMarker: String,
        recommendations: [ResearchRecommendation], followups: [ResearchFollowup],
        requiredHeadings: [String], predicates: [Predicate]
    ) {
        self.stepID = stepID
        self.taskMarker = taskMarker
        self.recommendations = recommendations
        self.followups = followups
        self.requiredHeadings = requiredHeadings
        self.predicates = predicates
    }

    public init(step: TaskStep) throws {
        guard step.tool == "research.create_note_and_followups" else {
            throw ResearchFollowupDraftError.wrongTool(step.tool)
        }
        stepID = step.id
        taskMarker = try Self.string("task_marker", in: step.arguments)
        recommendations = try Self.recommendations(in: step.arguments)
        followups = try Self.followups(in: step.arguments)
        requiredHeadings = try Self.stringArray("required_headings", in: step.arguments)
        predicates = step.postconditions
        guard recommendations.count == 3, followups.count == 3 else {
            throw ResearchFollowupDraftError.requiresExactlyThree
        }
    }

    private static func recommendations(
        in arguments: [String: JSONValue]
    ) throws -> [ResearchRecommendation] {
        guard case .array(let values)? = arguments["recommendations"] else {
            throw ResearchFollowupDraftError.missingArgument("recommendations")
        }
        return try values.map { value in
            guard case .object(let object) = value else {
                throw ResearchFollowupDraftError.missingArgument("recommendations")
            }
            return ResearchRecommendation(
                rank: try integer("rank", in: object),
                name: try string("name", in: object),
                url: try string("url", in: object),
                rationale: try string("rationale", in: object),
                summary: try string("summary", in: object),
                score: try integer("score", in: object))
        }
    }

    private static func followups(
        in arguments: [String: JSONValue]
    ) throws -> [ResearchFollowup] {
        guard case .array(let values)? = arguments["followups"] else {
            throw ResearchFollowupDraftError.missingArgument("followups")
        }
        return try values.map { value in
            guard case .object(let object) = value else {
                throw ResearchFollowupDraftError.missingArgument("followups")
            }
            return ResearchFollowup(
                company: try string("company", in: object),
                url: try string("url", in: object),
                title: try string("title", in: object),
                dueDate: try LocalDate(iso8601: string("due_date", in: object)))
        }
    }

    private static func stringArray(
        _ key: String, in values: [String: JSONValue]
    ) throws -> [String] {
        guard case .array(let raw)? = values[key] else {
            throw ResearchFollowupDraftError.missingArgument(key)
        }
        let result = raw.compactMap { value -> String? in
            guard case .string(let string) = value else { return nil }
            return string
        }
        guard !result.isEmpty else {
            throw ResearchFollowupDraftError.missingArgument(key)
        }
        return result
    }

    private static func string(
        _ key: String, in values: [String: JSONValue]
    ) throws -> String {
        guard case .string(let value)? = values[key], !value.isEmpty else {
            throw ResearchFollowupDraftError.missingArgument(key)
        }
        return value
    }

    private static func integer(
        _ key: String, in values: [String: JSONValue]
    ) throws -> Int {
        guard case .number(let value)? = values[key],
              value.rounded() == value
        else { throw ResearchFollowupDraftError.missingArgument(key) }
        return Int(value)
    }
}

public enum ResearchFollowupHTMLBuilder {
    public static func build(draft: ResearchFollowupDraft) -> String {
        let recommendationSections = draft.recommendations.map { item in
            """
            <h3>#\(item.rank) \(escapedHTML(item.name)) — score \(item.score)</h3>
            <p>\(escapedHTML(item.rationale))</p>
            <p>\(escapedHTML(item.summary))</p>
            <p><a href="\(escapedHTML(item.url))">\(escapedHTML(item.url))</a></p>
            <p>voiceops-recommendation:\(item.rank)</p>
            """
        }.joined(separator: "\n")
        let comparisonRows = draft.recommendations.map { item in
            "<tr><td>\(item.rank)</td><td>\(escapedHTML(item.name))</td><td>\(item.score)</td></tr>"
        }.joined()
        let sources = draft.recommendations.map { item in
            "<li><a href=\"\(escapedHTML(item.url))\">\(escapedHTML(item.name))</a></li>"
        }.joined()
        return """
        <h1>VoiceOps Research — Top 3 Companies</h1>
        <h2>Recommendations</h2>
        \(recommendationSections)
        <h2>Comparison</h2>
        <table><tr><th>Rank</th><th>Company</th><th>Score</th></tr>\(comparisonRows)</table>
        <h2>Sources</h2>
        <ul>\(sources)</ul>
        <p>\(escapedHTML(draft.taskMarker))</p>
        """
    }
}

private func escapedHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

public struct ResearchNoteRecord: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public struct ResearchFollowupRecord: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let company: String
    public let dueDate: LocalDate?
    public let notes: String?

    public init(
        identifier: String, title: String, company: String,
        dueDate: LocalDate?, notes: String?
    ) {
        self.identifier = identifier
        self.title = title
        self.company = company
        self.dueDate = dueDate
        self.notes = notes
    }
}

public enum ResearchFollowupVerificationEngine {
    public static func verify(
        draft: ResearchFollowupDraft,
        fetchedNote: ResearchNoteRecord?,
        fetchedFollowups: [ResearchFollowupRecord],
        visiblyDisplayed: Bool
    ) -> [VerificationResult] {
        var evidence = fetchedFollowups.map { "eventkit:\($0.identifier)" }
        if let fetchedNote { evidence.append("notes:\(fetchedNote.identifier)") }
        return draft.predicates.map { predicate in
            let result = evaluate(
                predicate, draft: draft, note: fetchedNote,
                followups: fetchedFollowups, visiblyDisplayed: visiblyDisplayed)
            return VerificationResult(
                predicateId: predicate.id, passed: result.passed,
                method: predicate.id == "research-visible"
                    ? "notes_ui" : "notes_eventkit_fetch_back",
                confidence: predicate.id == "research-visible" ? 0.95 : 1,
                expected: predicate.expected, observed: result.observed,
                evidenceIds: evidence,
                failureReason: result.passed ? nil : result.reason)
        }
    }

    private static func evaluate(
        _ predicate: Predicate,
        draft: ResearchFollowupDraft,
        note: ResearchNoteRecord?,
        followups: [ResearchFollowupRecord],
        visiblyDisplayed: Bool
    ) -> (passed: Bool, observed: [String: JSONValue], reason: String) {
        let body = note?.body ?? ""
        switch predicate.id {
        case "research-note-exists":
            let marker = body.contains(draft.taskMarker)
            return (
                note != nil && marker,
                ["note_id": note.map { .string($0.identifier) } ?? .null,
                 "task_marker_present": .bool(marker)],
                "The comparison note could not be fetched with its task marker.")
        case "research-exactly-three":
            let expectedMarkers = draft.recommendations.map {
                "voiceops-recommendation:\($0.rank)"
            }
            let markerCount = occurrences(of: "voiceops-recommendation:", in: body)
            let exactExpectedMarkers = expectedMarkers.allSatisfy {
                occurrences(of: $0, in: body) == 1
            }
            return (
                markerCount == 3 && exactExpectedMarkers,
                ["recommendation_count": .number(Double(markerCount))],
                "The fetched comparison note did not contain exactly three recommendations.")
        case "research-citations":
            let matched = draft.recommendations.filter {
                containsRawOrEscaped($0.url, in: body)
                    && containsRawOrEscaped($0.rationale, in: body)
            }
            return (
                matched.count == 3,
                ["matched_source_urls": .array(matched.map { .string($0.url) })],
                "One or more recommendations lacked its source URL or rationale.")
        case "research-followups":
            let matched = draft.followups.filter { expected in
                followups.contains { actual in
                    actual.title == expected.title
                        && actual.company == expected.company
                        && actual.dueDate == expected.dueDate
                        && actual.notes?.contains(expected.url) == true
                        && actual.notes?.contains(draft.taskMarker) == true
                }
            }
            return (
                followups.count == 3 && matched.count == 3,
                [
                    "count": .number(Double(followups.count)),
                    "matched_local_dates": .array(matched.map {
                        .string($0.dueDate.iso8601)
                    }),
                ],
                "The approved three follow-up reminders or dates did not match.")
        case "research-visible":
            return (
                visiblyDisplayed, ["visible": .bool(visiblyDisplayed)],
                "The research note exists, but VoiceOps could not show it in Notes.")
        default:
            return (
                false, ["unsupported_predicate": .string(predicate.id)],
                "The verifier does not implement this predicate.")
        }
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private static func containsRawOrEscaped(_ value: String, in body: String) -> Bool {
        body.contains(value) || body.contains(escapedHTML(value))
    }
}
