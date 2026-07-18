import Foundation

/// User-visible session states (PRD §9). One active session at a time.
public enum SessionState: Equatable, Sendable {
    case idle
    case listening(transcript: String)
    case planning(transcript: String)
    case acting(description: String)
    case verifying
    case result(SessionResult)
}

public enum SessionResult: Equatable, Sendable {
    case completed(state: TaskState, summary: String)
    case failed(reason: String)
    case cancelled
}

public enum SessionEvent: Equatable, Sendable {
    case hotkeyTapped
    case partialTranscript(String)
    case finalTranscript(String)
    case planReady(summary: String)
    case verificationStarted
    case taskCompleted(state: TaskState, summary: String)
    case taskFailed(reason: String)
    case stopRequested
    case dismissResult
}

/// Pure reducer: (state, event) -> next state, or nil when the event is
/// meaningless in that state. Side effects (starting capture, cancelling the
/// sidecar, TTS) belong to the coordinator observing the transitions.
public enum SessionStateMachine {
    public static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (.idle, .hotkeyTapped):
            return .listening(transcript: "")

        case (.listening, .partialTranscript(let text)):
            return .listening(transcript: text)
        case (.listening(let transcript), .hotkeyTapped):
            return .planning(transcript: transcript)
        case (.listening, .finalTranscript(let text)):
            return .planning(transcript: text)
        case (.listening, .stopRequested):
            return .idle

        case (.planning, .finalTranscript(let text)):
            return .planning(transcript: text)
        case (.planning, .planReady(let summary)):
            return .acting(description: summary)

        case (.acting, .verificationStarted):
            return .verifying

        case (.acting, .taskCompleted(let taskState, let summary)),
             (.verifying, .taskCompleted(let taskState, let summary)):
            return .result(.completed(state: taskState, summary: summary))

        case (.listening, .taskFailed(let reason)),
             (.planning, .taskFailed(let reason)),
             (.acting, .taskFailed(let reason)),
             (.verifying, .taskFailed(let reason)):
            return .result(.failed(reason: reason))

        case (.planning, .stopRequested),
             (.acting, .stopRequested),
             (.verifying, .stopRequested):
            return .result(.cancelled)

        case (.result, .dismissResult):
            return .idle

        default:
            return nil
        }
    }
}
