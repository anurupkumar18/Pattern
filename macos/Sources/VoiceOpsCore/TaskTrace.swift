import Foundation

public enum TaskTraceStage: String, Codable, Equatable, Sendable {
    case listening, grounding, planning, approval, action, recovery, verification, outcome
}

public struct TaskTraceEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let stage: TaskTraceStage
    public let message: String
    public let elapsedMilliseconds: Int

    public init(
        id: UUID = UUID(), stage: TaskTraceStage, message: String,
        elapsedMilliseconds: Int
    ) {
        self.id = id
        self.stage = stage
        self.message = message
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
    }
}

public struct TaskTrace: Equatable, Sendable {
    public let startedAt: Date
    public private(set) var entries: [TaskTraceEntry]

    public init(startedAt: Date = Date(), entries: [TaskTraceEntry] = []) {
        self.startedAt = startedAt
        self.entries = entries
    }

    public var recoveryCount: Int {
        entries.count { $0.stage == .recovery }
    }

    public var totalElapsedMilliseconds: Int {
        entries.last?.elapsedMilliseconds ?? 0
    }

    public mutating func record(
        _ stage: TaskTraceStage, _ message: String, at date: Date = Date()
    ) {
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt) * 1_000))
        entries.append(TaskTraceEntry(
            stage: stage, message: message, elapsedMilliseconds: elapsed))
    }
}
