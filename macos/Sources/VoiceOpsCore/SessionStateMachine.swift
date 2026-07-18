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
    /// Hotkey-bounded speech-to-speech session: the mic is live, the agent may
    /// be speaking, and the task version tracks the sidecar's authority.
    case conversing(agentSpeaking: Bool, planVersion: Int?, transcript: String)
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
    case conversationOpened
    case conversationClosed
    case agentSpeechStarted
    case agentSpeechEnded
    case conversationFallback(objective: String?)
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

        // -- speech-to-speech conversation session --------------------------
        case (.idle, .conversationOpened):
            return .conversing(agentSpeaking: false, planVersion: nil, transcript: "")
        case (.conversing(let speaking, let version, _), .partialTranscript(let text)):
            return .conversing(
                agentSpeaking: speaking, planVersion: version, transcript: text)
        case (.conversing(let speaking, _, let transcript), .taskSpecReady(let version, _)):
            return .conversing(
                agentSpeaking: speaking, planVersion: version, transcript: transcript)
        case (.conversing(_, let version, let transcript), .agentSpeechStarted):
            return .conversing(
                agentSpeaking: true, planVersion: version, transcript: transcript)
        case (.conversing(_, let version, let transcript), .agentSpeechEnded):
            return .conversing(
                agentSpeaking: false, planVersion: version, transcript: transcript)
        case (.conversing, .stopRequested):
            return .result(.cancelled)
        case (.conversing(_, .none, _), .conversationClosed):
            return .idle
        case (.conversing(_, .some, _), .conversationClosed):
            return nil  // an open task ends via taskCompleted/taskFailed only
        case (.conversing, .taskCompleted(let taskState, let summary)):
            return .result(.completed(state: taskState, summary: summary))
        case (.conversing, .taskFailed(let reason)):
            return .result(.failed(reason: reason))
        case (.conversing(_, .some(let version), _),
              .conversationFallback(let objective)):
            return .readyForCorrection(
                objective: objective ?? "Active task",
                version: version,
                groundingChips: [])
        case (.conversing(_, .none, let transcript), .conversationFallback):
            return .listening(transcript: transcript)

        default:
            return nil
        }
    }
}
