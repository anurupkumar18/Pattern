import Foundation

/// Swift mirror of the wire contract defined in agent/voiceops_agent/schemas.py
/// (the source of truth — see docs/DECISIONS.md ADR-007). Phase 0 carries typed
/// payloads for the mock exchange events; remaining event payloads land with
/// the phases that first use them.
public enum EventType: String, Codable, Sendable, CaseIterable {
    case voicePartial = "voice.partial"
    case voiceFinal = "voice.final"
    case observationReady = "observation.ready"
    case groundingReady = "grounding.ready"
    case planReady = "plan.ready"
    case approvalRequested = "approval.requested"
    case actionStarted = "action.started"
    case actionFinished = "action.finished"
    case verificationFinished = "verification.finished"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskCancelled = "task.cancelled"
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

public struct VerificationResult: Codable, Equatable, Sendable {
    public let predicateId: String
    public let passed: Bool
    public let method: String
    public let confidence: Double
    public let expected: [String: JSONValue]
    public let observed: [String: JSONValue]
    public let evidenceIds: [String]
    public let failureReason: String?

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
}

public struct TaskFailure: Codable, Equatable, Sendable {
    public let error: StructuredError
    public let summary: String?
}

public struct TaskCancelled: Codable, Equatable, Sendable {
    public let reason: String?
}

public enum EventPayload: Equatable, Sendable {
    case voiceFinal(VoiceRequest)
    case planReady(TaskPlan)
    case taskCompleted(TaskCompleted)
    case taskFailed(TaskFailure)
    case taskCancelled(TaskCancelled)
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
        self.timestamp = timestamp
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
        case .voiceFinal:
            self.payload = .voiceFinal(try container.decode(VoiceRequest.self, forKey: .payload))
        case .planReady:
            self.payload = .planReady(try container.decode(TaskPlan.self, forKey: .payload))
        case .taskCompleted:
            self.payload = .taskCompleted(try container.decode(TaskCompleted.self, forKey: .payload))
        case .taskFailed:
            self.payload = .taskFailed(try container.decode(TaskFailure.self, forKey: .payload))
        case .taskCancelled:
            self.payload = .taskCancelled(try container.decode(TaskCancelled.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .payload, in: container,
                debugDescription: "payload for \(type.rawValue) is not implemented in Phase 0")
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
        case .voiceFinal(let value): try container.encode(value, forKey: .payload)
        case .planReady(let value): try container.encode(value, forKey: .payload)
        case .taskCompleted(let value): try container.encode(value, forKey: .payload)
        case .taskFailed(let value): try container.encode(value, forKey: .payload)
        case .taskCancelled(let value): try container.encode(value, forKey: .payload)
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
