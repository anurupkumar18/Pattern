import Foundation

/// Swift mirror of the wire contract defined in agent/voiceops_agent/schemas.py
/// (the source of truth — see docs/DECISIONS.md ADR-007). Every declared event
/// has a typed payload on both sides of the process boundary.
public enum EventType: String, Codable, Sendable, CaseIterable {
    case voicePartial = "voice.partial"
    case voiceFinal = "voice.final"
    case voiceCorrection = "voice.correction"
    case observationReady = "observation.ready"
    case groundingReady = "grounding.ready"
    case planReady = "plan.ready"
    case taskSpecReady = "task.spec_ready"
    case planPatchApplied = "plan.patch_applied"
    case ledgerEvent = "ledger.event"
    case approvalRequested = "approval.requested"
    case actionStarted = "action.started"
    case actionFinished = "action.finished"
    case verificationFinished = "verification.finished"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskCancelled = "task.cancelled"
    case conversationToolCall = "conversation.tool_call"
    case conversationToolResult = "conversation.tool_result"
}

public enum Risk: String, Codable, Sendable {
    case read
    case reversibleWrite = "reversible_write"
    case consequential
    case destructive
}

public enum TaskState: String, Codable, Sendable {
    case succeeded, partial, failed
    case needsUser = "needs_user"
}

public enum TaskActionStatus: String, Codable, Sendable {
    case pending, completed, cancelled
}

public enum PatchOperationKind: String, Codable, Sendable {
    case add, remove, replace
}

public enum LedgerEventKind: String, Codable, Sendable {
    case observed, interpreted, decided, acted, verified
}

// MARK: - Arbitrary JSON values (step arguments, predicate expectations)

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Payload models

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Double

    public init(text: String, startMs: Int, endMs: Int, confidence: Double) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
    }
}

public struct TranscriptPartial: Codable, Equatable, Sendable {
    public let transcript: String
    public let confidence: Double?
    public let locale: String?

    public init(transcript: String, confidence: Double? = nil, locale: String? = nil) {
        self.transcript = transcript
        self.confidence = confidence
        self.locale = locale
    }
}

public struct VoiceRequest: Codable, Equatable, Sendable {
    public let transcript: String
    public let locale: String
    public let confidence: Double
    public let segments: [TranscriptSegment]

    public init(transcript: String, locale: String, confidence: Double, segments: [TranscriptSegment]) {
        self.transcript = transcript
        self.locale = locale
        self.confidence = confidence
        self.segments = segments
    }
}

public struct Predicate: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let expected: [String: JSONValue]
}

public struct VerifierSpec: Codable, Equatable, Sendable {
    public let kind: String
    public let description: String
}

public struct TaskStep: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let tool: String
    public let arguments: [String: JSONValue]
    public let preconditions: [Predicate]
    public let postconditions: [Predicate]
    public let risk: Risk
    public let requiresConfirmation: Bool
    public let fallbackTools: [String]
    public let maxAttempts: Int
    public let timeoutSeconds: Int
    public let verifier: VerifierSpec

    enum CodingKeys: String, CodingKey {
        case id, description, tool, arguments, preconditions, postconditions, risk, verifier
        case requiresConfirmation = "requires_confirmation"
        case fallbackTools = "fallback_tools"
        case maxAttempts = "max_attempts"
        case timeoutSeconds = "timeout_seconds"
    }
}

public struct TaskPlan: Codable, Equatable, Sendable {
    public let goal: String
    public let summary: String
    public let steps: [TaskStep]
}

// MARK: - Persistent, versioned task and execution ledger

public struct TaskActionDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let risk: Risk
    public let requiresConfirmation: Bool
    public let status: TaskActionStatus

    enum CodingKeys: String, CodingKey {
        case id, description, risk, status
        case requiresConfirmation = "requires_confirmation"
    }
}

public struct PlanPatchOperation: Codable, Equatable, Sendable {
    public let operation: PatchOperationKind
    public let target: String
    public let value: JSONValue?
}

public struct AppliedPlanPatch: Codable, Equatable, Sendable {
    public let baseVersion: Int
    public let newVersion: Int
    public let transcript: String
    public let operations: [PlanPatchOperation]
    public let added: [String]
    public let removed: [String]
    public let replaced: [String]
    public let preserved: [String]

    enum CodingKeys: String, CodingKey {
        case transcript, operations, added, removed, replaced, preserved
        case baseVersion = "base_version"
        case newVersion = "new_version"
    }
}

public struct VersionedTaskSpec: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let version: Int
    public let rawRequest: String
    public let objective: String
    public let entities: [String: String]
    public let evidenceToCollect: [String]
    public let actions: [String: TaskActionDefinition]
    public let constraints: [String: String]
    public let completionCriteria: [String: String]
    public let provenance: [String: [String]]
    public let patchHistory: [AppliedPlanPatch]

    enum CodingKeys: String, CodingKey {
        case version, objective, entities, actions, constraints, provenance
        case taskID = "task_id"
        case rawRequest = "raw_request"
        case evidenceToCollect = "evidence_to_collect"
        case completionCriteria = "completion_criteria"
        case patchHistory = "patch_history"
    }
}

public struct ExecutionLedgerEvent: Equatable, Sendable {
    public let sequence: Int
    public let timestamp: Date
    public let eventType: LedgerEventKind
    public let whereText: String
    public let what: String
    public let found: String?
    public let source: String
    public let whyItMatters: String
    public let confidence: Double
    public let next: String?
}

extension ExecutionLedgerEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case sequence, timestamp, what, found, source, confidence, next
        case eventType = "event_type"
        case whereText = "where"
        case whyItMatters = "why_it_matters"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        let rawTimestamp = try container.decode(String.self, forKey: .timestamp)
        guard let date = WireDate.parse(rawTimestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container,
                debugDescription: "ledger timestamp is not ISO-8601: \(rawTimestamp)")
        }
        timestamp = date
        eventType = try container.decode(LedgerEventKind.self, forKey: .eventType)
        whereText = try container.decode(String.self, forKey: .whereText)
        what = try container.decode(String.self, forKey: .what)
        found = try container.decodeIfPresent(String.self, forKey: .found)
        source = try container.decode(String.self, forKey: .source)
        whyItMatters = try container.decode(String.self, forKey: .whyItMatters)
        confidence = try container.decode(Double.self, forKey: .confidence)
        next = try container.decodeIfPresent(String.self, forKey: .next)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(WireDate.format(timestamp), forKey: .timestamp)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(whereText, forKey: .whereText)
        try container.encode(what, forKey: .what)
        try container.encodeIfPresent(found, forKey: .found)
        try container.encode(source, forKey: .source)
        try container.encode(whyItMatters, forKey: .whyItMatters)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(next, forKey: .next)
    }
}

public struct ApprovalRequest: Codable, Equatable, Sendable {
    public let stepID: String
    public let description: String
    public let risk: Risk
    public let dataPreview: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case description, risk
        case stepID = "step_id"
        case dataPreview = "data_preview"
    }
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public let predicateId: String
    public let passed: Bool
    public let method: String
    public let confidence: Double
    public let expected: [String: JSONValue]
    public let observed: [String: JSONValue]
    public let evidenceIds: [String]
    public let failureReason: String?

    public init(
        predicateId: String,
        passed: Bool,
        method: String,
        confidence: Double,
        expected: [String: JSONValue],
        observed: [String: JSONValue],
        evidenceIds: [String],
        failureReason: String?
    ) {
        self.predicateId = predicateId
        self.passed = passed
        self.method = method
        self.confidence = confidence
        self.expected = expected
        self.observed = observed
        self.evidenceIds = evidenceIds
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case passed, method, confidence, expected, observed
        case predicateId = "predicate_id"
        case evidenceIds = "evidence_ids"
        case failureReason = "failure_reason"
    }
}

public struct TaskCompleted: Codable, Equatable, Sendable {
    public let state: TaskState
    public let summary: String
    public let verification: [VerificationResult]
}

public struct StructuredError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]

    public init(code: String, message: String, details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public enum ActionStatus: String, Codable, Equatable, Sendable {
    case executed, noOp = "no_op", failed, uncertain
}

public struct ActionStarted: Codable, Equatable, Sendable {
    public let stepId: String
    public let tool: String
    public let channel: String

    enum CodingKeys: String, CodingKey {
        case tool, channel
        case stepId = "step_id"
    }
}

public struct ActionResult: Equatable, Sendable {
    public let stepId: String
    public let status: ActionStatus
    public let startedAt: Date
    public let endedAt: Date
    public let channel: String
    public let targetProvenance: [String: JSONValue]
    public let rawResult: [String: JSONValue]
    public let stateChangeHint: String?
    public let error: StructuredError?

    public init(
        stepId: String,
        status: ActionStatus,
        startedAt: Date,
        endedAt: Date,
        channel: String,
        targetProvenance: [String: JSONValue] = [:],
        rawResult: [String: JSONValue] = [:],
        stateChangeHint: String? = nil,
        error: StructuredError? = nil
    ) {
        self.stepId = stepId
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.channel = channel
        self.targetProvenance = targetProvenance
        self.rawResult = rawResult
        self.stateChangeHint = stateChangeHint
        self.error = error
    }
}

extension ActionResult: Codable {
    enum CodingKeys: String, CodingKey {
        case status, channel, error
        case stepId = "step_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case targetProvenance = "target_provenance"
        case rawResult = "raw_result"
        case stateChangeHint = "state_change_hint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepId = try container.decode(String.self, forKey: .stepId)
        status = try container.decode(ActionStatus.self, forKey: .status)
        startedAt = try Self.decodeDate(container, key: .startedAt)
        endedAt = try Self.decodeDate(container, key: .endedAt)
        channel = try container.decode(String.self, forKey: .channel)
        targetProvenance = try container.decode(
            [String: JSONValue].self, forKey: .targetProvenance)
        rawResult = try container.decode([String: JSONValue].self, forKey: .rawResult)
        stateChangeHint = try container.decodeIfPresent(String.self, forKey: .stateChangeHint)
        error = try container.decodeIfPresent(StructuredError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepId, forKey: .stepId)
        try container.encode(status, forKey: .status)
        try container.encode(WireDate.format(startedAt), forKey: .startedAt)
        try container.encode(WireDate.format(endedAt), forKey: .endedAt)
        try container.encode(channel, forKey: .channel)
        try container.encode(targetProvenance, forKey: .targetProvenance)
        try container.encode(rawResult, forKey: .rawResult)
        try container.encodeIfPresent(stateChangeHint, forKey: .stateChangeHint)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let value = WireDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "action timestamp is not ISO-8601: \(raw)")
        }
        return value
    }
}

public struct TaskFailure: Codable, Equatable, Sendable {
    public let error: StructuredError
    public let summary: String?
}

public struct TaskCancelled: Codable, Equatable, Sendable {
    public let reason: String?
}

/// The S2S conversation layer's only side-effect path into the task machine.
public struct ConversationToolCall: Codable, Equatable, Sendable {
    public let callID: String
    public let tool: String
    public let arguments: [String: JSONValue]

    public init(callID: String, tool: String, arguments: [String: JSONValue] = [:]) {
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case tool, arguments
        case callID = "call_id"
    }
}

public struct ConversationToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let tool: String
    public let status: String
    public let result: [String: JSONValue]
    public let error: StructuredError?

    public init(
        callID: String,
        tool: String,
        status: String,
        result: [String: JSONValue] = [:],
        error: StructuredError? = nil
    ) {
        self.callID = callID
        self.tool = tool
        self.status = status
        self.result = result
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case tool, status, result, error
        case callID = "call_id"
    }
}

/// Read-back approval: a spoken yes authorizes exactly one action-set hash.
public struct ApprovalBinding: Codable, Equatable, Sendable {
    public let bindingHash: String
    public let taskVersion: Int
    public let readBack: String
    public let actionIDs: [String]

    public init(bindingHash: String, taskVersion: Int, readBack: String, actionIDs: [String]) {
        self.bindingHash = bindingHash
        self.taskVersion = taskVersion
        self.readBack = readBack
        self.actionIDs = actionIDs
    }

    enum CodingKeys: String, CodingKey {
        case bindingHash = "binding_hash"
        case taskVersion = "task_version"
        case readBack = "read_back"
        case actionIDs = "action_ids"
    }
}

public enum EventPayload: Equatable, Sendable {
    case voicePartial(TranscriptPartial)
    case voiceFinal(VoiceRequest)
    case voiceCorrection(VoiceRequest)
    case observationReady(Observation)
    case groundingReady(GroundingResult)
    case planReady(TaskPlan)
    case taskSpecReady(VersionedTaskSpec)
    case planPatchApplied(AppliedPlanPatch)
    case ledgerEvent(ExecutionLedgerEvent)
    case approvalRequested(ApprovalRequest)
    case actionStarted(ActionStarted)
    case actionFinished(ActionResult)
    case verificationFinished(VerificationResult)
    case taskCompleted(TaskCompleted)
    case taskFailed(TaskFailure)
    case taskCancelled(TaskCancelled)
    case conversationToolCall(ConversationToolCall)
    case conversationToolResult(ConversationToolResult)
}

// MARK: - Envelope

public struct Envelope: Equatable, Sendable {
    public static let protocolVersion = "1.0"

    public let version: String
    public let id: UUID
    public let type: EventType
    public let taskID: UUID
    public let timestamp: Date
    public let payload: EventPayload

    public init(id: UUID = UUID(), type: EventType, taskID: UUID, timestamp: Date = .now, payload: EventPayload) {
        self.version = Self.protocolVersion
        self.id = id
        self.type = type
        self.taskID = taskID
        // Match schemas.make_envelope: strict whole-second UTC on the wire and
        // in memory so encode/decode round-trips remain value-equal.
        self.timestamp = Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970))
        self.payload = payload
    }
}

extension Envelope: Codable {
    enum CodingKeys: String, CodingKey {
        case version, id, type, timestamp, payload
        case taskID = "task_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let version = try container.decode(String.self, forKey: .version)
        guard version == Self.protocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "unsupported protocol version \(version)")
        }
        self.version = version

        self.id = try Self.decodeUUID(container, .id)
        self.taskID = try Self.decodeUUID(container, .taskID)
        self.type = try container.decode(EventType.self, forKey: .type)

        let rawTimestamp = try container.decode(String.self, forKey: .timestamp)
        guard let date = WireDate.parse(rawTimestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container,
                debugDescription: "timestamp is not ISO-8601: \(rawTimestamp)")
        }
        self.timestamp = date

        switch type {
        case .voicePartial:
            self.payload = .voicePartial(
                try container.decode(TranscriptPartial.self, forKey: .payload))
        case .voiceFinal:
            self.payload = .voiceFinal(try container.decode(VoiceRequest.self, forKey: .payload))
        case .voiceCorrection:
            self.payload = .voiceCorrection(try container.decode(VoiceRequest.self, forKey: .payload))
        case .observationReady:
            self.payload = .observationReady(try container.decode(Observation.self, forKey: .payload))
        case .groundingReady:
            self.payload = .groundingReady(try container.decode(GroundingResult.self, forKey: .payload))
        case .planReady:
            self.payload = .planReady(try container.decode(TaskPlan.self, forKey: .payload))
        case .taskSpecReady:
            self.payload = .taskSpecReady(
                try container.decode(VersionedTaskSpec.self, forKey: .payload))
        case .planPatchApplied:
            self.payload = .planPatchApplied(
                try container.decode(AppliedPlanPatch.self, forKey: .payload))
        case .ledgerEvent:
            self.payload = .ledgerEvent(
                try container.decode(ExecutionLedgerEvent.self, forKey: .payload))
        case .approvalRequested:
            self.payload = .approvalRequested(
                try container.decode(ApprovalRequest.self, forKey: .payload))
        case .actionStarted:
            self.payload = .actionStarted(try container.decode(ActionStarted.self, forKey: .payload))
        case .actionFinished:
            self.payload = .actionFinished(try container.decode(ActionResult.self, forKey: .payload))
        case .verificationFinished:
            self.payload = .verificationFinished(
                try container.decode(VerificationResult.self, forKey: .payload))
        case .taskCompleted:
            self.payload = .taskCompleted(try container.decode(TaskCompleted.self, forKey: .payload))
        case .taskFailed:
            self.payload = .taskFailed(try container.decode(TaskFailure.self, forKey: .payload))
        case .taskCancelled:
            self.payload = .taskCancelled(try container.decode(TaskCancelled.self, forKey: .payload))
        case .conversationToolCall:
            self.payload = .conversationToolCall(
                try container.decode(ConversationToolCall.self, forKey: .payload))
        case .conversationToolResult:
            self.payload = .conversationToolResult(
                try container.decode(ConversationToolResult.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(taskID.uuidString.lowercased(), forKey: .taskID)
        try container.encode(WireDate.format(timestamp), forKey: .timestamp)
        switch payload {
        case .voicePartial(let value): try container.encode(value, forKey: .payload)
        case .voiceFinal(let value): try container.encode(value, forKey: .payload)
        case .voiceCorrection(let value): try container.encode(value, forKey: .payload)
        case .observationReady(let value): try container.encode(value, forKey: .payload)
        case .groundingReady(let value): try container.encode(value, forKey: .payload)
        case .planReady(let value): try container.encode(value, forKey: .payload)
        case .taskSpecReady(let value): try container.encode(value, forKey: .payload)
        case .planPatchApplied(let value): try container.encode(value, forKey: .payload)
        case .ledgerEvent(let value): try container.encode(value, forKey: .payload)
        case .approvalRequested(let value): try container.encode(value, forKey: .payload)
        case .actionStarted(let value): try container.encode(value, forKey: .payload)
        case .actionFinished(let value): try container.encode(value, forKey: .payload)
        case .verificationFinished(let value): try container.encode(value, forKey: .payload)
        case .taskCompleted(let value): try container.encode(value, forKey: .payload)
        case .taskFailed(let value): try container.encode(value, forKey: .payload)
        case .taskCancelled(let value): try container.encode(value, forKey: .payload)
        case .conversationToolCall(let value): try container.encode(value, forKey: .payload)
        case .conversationToolResult(let value): try container.encode(value, forKey: .payload)
        }
    }

    private static func decodeUUID(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> UUID {
        let raw = try container.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "invalid UUID: \(raw)")
        }
        return uuid
    }
}

extension Envelope {
    public static func decode(from data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }

    public func encodeWire() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// One complete envelope per line — the sidecar's framing.
    public func ndjsonLine() throws -> String {
        guard let json = String(data: try encodeWire(), encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: [], debugDescription: "envelope is not valid UTF-8"))
        }
        return json + "\n"
    }
}

/// Wire timestamps are whole-second UTC with a Z suffix (see schemas.make_envelope).
/// Parsing also accepts fractional seconds defensively.
enum WireDate {
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
