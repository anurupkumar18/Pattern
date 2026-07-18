import Foundation

public enum RecoveryAction: Equatable, Sendable {
    case complete
    case retrySameTarget(reason: String)
    case reobserveAndRetry(reason: String)
    case openAppAndRetry(reason: String)
    case requestPermission(settingsURL: String?)
    case verifyWithoutRetry(reason: String)
    case stop(reason: String)
}

/// Deterministic recovery boundary. Model output cannot increase retry budgets,
/// retry an uncertain write, or retry consequential/destructive work.
public enum RecoveryPolicy {
    public static func decide(
        status: ActionStatus,
        error: StructuredError?,
        risk: Risk,
        attempt: Int,
        maxAttempts: Int
    ) -> RecoveryAction {
        if status == .executed || status == .noOp { return .complete }

        let code = error?.code ?? "UNKNOWN"
        if status == .uncertain || code == "CONSEQUENTIAL_STATE_UNCERTAIN" {
            return .verifyWithoutRetry(
                reason: "The prior state change is uncertain; VoiceOps will verify or ask instead of retrying.")
        }
        if code == "PERMISSION_DENIED" {
            return .requestPermission(settingsURL: string("settings_url", in: error?.details))
        }
        if risk == .consequential || risk == .destructive {
            return .verifyWithoutRetry(
                reason: "Consequential or destructive work is never repeated automatically.")
        }
        guard attempt < max(1, maxAttempts) else {
            return .stop(reason: "The bounded recovery budget is exhausted.")
        }

        switch code {
        case "NO_STATE_CHANGE", "TIMEOUT":
            return .retrySameTarget(
                reason: "No committed state change was observed; retrying the same semantic target once.")
        case "TARGET_STALE", "TARGET_NOT_FOUND":
            return .reobserveAndRetry(
                reason: "The target changed or disappeared; refresh context before retrying.")
        case "APP_NOT_RUNNING":
            return .openAppAndRetry(
                reason: "The required application is not running; reopen and refresh before retrying.")
        case "AMBIGUOUS_STATE", "MODEL_INVALID_OUTPUT":
            return .stop(reason: error?.message ?? "The state needs user input.")
        default:
            return .stop(reason: error?.message ?? "The action failed without a safe recovery path.")
        }
    }

    private static func string(
        _ key: String, in details: [String: JSONValue]?
    ) -> String? {
        guard case .string(let value)? = details?[key] else { return nil }
        return value
    }
}

public enum AttemptClaim: Equatable, Sendable {
    case allowed(attempt: Int)
    case rejectedCompleted
    case rejectedUncertain
    case rejectedBudget
}

/// Task-scoped duplicate guard used before every native write attempt.
public struct ActionAttemptLedger: Sendable {
    private struct Key: Hashable, Sendable {
        let taskID: UUID
        let stepID: String
    }

    private struct Record: Sendable {
        var attempts = 0
        var lastStatus: ActionStatus?
    }

    private var records: [Key: Record] = [:]

    public init() {}

    public mutating func claim(
        taskID: UUID, stepID: String, maxAttempts: Int
    ) -> AttemptClaim {
        let key = Key(taskID: taskID, stepID: stepID)
        var record = records[key] ?? Record()
        if record.lastStatus == .executed || record.lastStatus == .noOp {
            return .rejectedCompleted
        }
        if record.lastStatus == .uncertain { return .rejectedUncertain }
        guard record.attempts < max(1, maxAttempts) else { return .rejectedBudget }
        record.attempts += 1
        records[key] = record
        return .allowed(attempt: record.attempts)
    }

    public mutating func finish(
        taskID: UUID, stepID: String, status: ActionStatus
    ) {
        let key = Key(taskID: taskID, stepID: stepID)
        var record = records[key] ?? Record()
        record.lastStatus = status
        records[key] = record
    }

    public mutating func remove(taskID: UUID) {
        records = records.filter { $0.key.taskID != taskID }
    }
}

public enum PanicStopPolicy {
    public static let escapeKeyCode: Int64 = 53

    public static func shouldCancel(keyCode: Int64, isArmed: Bool) -> Bool {
        isArmed && keyCode == escapeKeyCode
    }
}
