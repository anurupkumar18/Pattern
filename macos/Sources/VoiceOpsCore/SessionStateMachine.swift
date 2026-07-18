import Foundation

/// User-visible session states (PRD §9). One active session at a time.
public enum SessionState: Equatable, Sendable {
    case idle
    case listening(transcript: String)
    case grounding(transcript: String)
    case planning(transcript: String, groundingChips: [GroundingChip])
    case readyForCorrection(objective: String, version: Int, groundingChips: [GroundingChip])
    case correctionListening(transcript: String, planVersion: Int, groundingChips: [GroundingChip])
    case awaitingApproval(description: String, groundingChips: [GroundingChip])
    case acting(description: String, groundingChips: [GroundingChip])
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
    case groundingReady([GroundingChip])
    case planReady(summary: String)
    case taskSpecReady(version: Int, objective: String)
    case approvalRequested(description: String)
    case approvalGranted
    case approvalDenied
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
            return .grounding(transcript: transcript)
        case (.listening, .finalTranscript(let text)):
            return .grounding(transcript: text)
        case (.listening, .stopRequested):
            return .idle

        case (.grounding, .finalTranscript(let text)):
            return .grounding(transcript: text)
        case (.grounding(let transcript), .groundingReady(let chips)):
            return .planning(transcript: transcript, groundingChips: chips)
        case (.planning(_, let chips), .planReady(let summary)):
            return .acting(description: summary, groundingChips: chips)
        case (.planning(_, let chips), .taskSpecReady(let version, let objective)):
            return .readyForCorrection(
                objective: objective, version: version, groundingChips: chips)
        case (.readyForCorrection(_, let version, let chips), .hotkeyTapped):
            return .correctionListening(
                transcript: "", planVersion: version, groundingChips: chips)
        case (.correctionListening(_, let version, let chips), .partialTranscript(let text)):
            return .correctionListening(
                transcript: text, planVersion: version, groundingChips: chips)
        case (.correctionListening(_, _, let chips), .hotkeyTapped),
             (.correctionListening(_, _, let chips), .finalTranscript):
            return .acting(
                description: "Applying correction to the existing plan",
                groundingChips: chips)
        case (.planning(_, let chips), .approvalRequested(let description)):
            return .awaitingApproval(description: description, groundingChips: chips)
        case (.awaitingApproval(let description, let chips), .approvalGranted):
            return .acting(description: description, groundingChips: chips)
        case (.awaitingApproval, .approvalDenied):
            return .result(.cancelled)

        case (.acting, .verificationStarted):
            return .verifying

        case (.acting, .taskCompleted(let taskState, let summary)),
             (.verifying, .taskCompleted(let taskState, let summary)):
            return .result(.completed(state: taskState, summary: summary))

        case (.listening, .taskFailed(let reason)),
             (.planning, .taskFailed(let reason)),
             (.readyForCorrection, .taskFailed(let reason)),
             (.correctionListening, .taskFailed(let reason)),
             (.awaitingApproval, .taskFailed(let reason)),
             (.grounding, .taskFailed(let reason)),
             (.acting, .taskFailed(let reason)),
             (.verifying, .taskFailed(let reason)):
            return .result(.failed(reason: reason))

        case (.grounding, .stopRequested),
             (.planning, .stopRequested),
             (.readyForCorrection, .stopRequested),
             (.correctionListening, .stopRequested),
             (.awaitingApproval, .stopRequested),
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
