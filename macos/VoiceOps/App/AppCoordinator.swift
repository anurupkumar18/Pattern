import AppKit
import Foundation
import VoiceOpsCore

/// Owns the session: hotkey → capture → sidecar exchange → companion state.
/// All state changes flow through SessionStateMachine.reduce; this class only
/// runs the side effects for transitions the machine has already approved.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle

    private let narrator = Narrator()
    private var hotKey: HotKeyManager?
    private var panel: CompanionPanelController?
    private var voiceSession: VoiceSessionController?
    private var sidecarClient: SidecarClient?
    private var sidecarTask: Task<Void, Never>?
    private var permissionsGranted = false

    /// Dev builds run the sidecar straight from the repo checkout; packaged
    /// builds set VOICEOPS_AGENT_DIR (packaging arrives in a later phase).
    static let agentProjectURL: URL = {
        if let override = ProcessInfo.processInfo.environment["VOICEOPS_AGENT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // VoiceOps
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("agent")
    }()

    init() {
        hotKey = HotKeyManager { [weak self] in self?.dispatch(.hotkeyTapped) }
        panel = CompanionPanelController(coordinator: self)
    }

    func toggle() { dispatch(.hotkeyTapped) }
    func stop() { dispatch(.stopRequested) }
    func dismiss() { dispatch(.dismissResult) }

    func dispatch(_ event: SessionEvent) {
        guard let next = SessionStateMachine.reduce(state, event) else { return }
        let previous = state
        state = next
        runEffects(from: previous, event: event, to: next)
    }

    private func runEffects(from previous: SessionState, event: SessionEvent, to state: SessionState) {
        switch state {
        case .idle:
            if case .listening = previous { cancelCapture() }
            panel?.hide()

        case .listening:
            panel?.show()
            narrator.say("Listening")
            startCapture()

        case .planning:
            if case .listening = previous {
                narrator.say("Got it")
                finishCaptureAndStartTask()
            }

        case .acting:
            narrator.say("Working on it")

        case .verifying:
            narrator.say("Verifying")

        case .result(let result):
            switch result {
            case .completed: narrator.say("Done")
            case .failed: narrator.say("That didn't work")
            case .cancelled: narrator.say("Stopped")
            }
            cancelCapture()
            cancelSidecar()
        }
    }

    // MARK: Capture

    private func startCapture() {
        Task { [weak self] in
            guard let self else { return }
            if !permissionsGranted {
                permissionsGranted = await SpeechTranscriber.requestPermissions()
            }
            guard permissionsGranted else {
                dispatch(.taskFailed(reason:
                    "Microphone or Speech Recognition permission is missing. "
                    + "Enable both for VoiceOps in System Settings → Privacy & Security."))
                return
            }
            // The user may have cancelled while the permission dialog was up.
            guard case .listening = state else { return }

            let controller = VoiceSessionController(
                transcriber: SpeechTranscriber(),
                locale: Locale.current.identifier(.bcp47))
            controller.onPartial = { [weak self] in self?.dispatch(.partialTranscript($0)) }
            controller.onAutoFinal = { [weak self] in self?.dispatch(.finalTranscript($0)) }
            voiceSession = controller
            do {
                try await controller.begin()
            } catch {
                dispatch(.taskFailed(reason: "Could not start audio capture: \(error.localizedDescription)"))
            }
        }
    }

    private func finishCaptureAndStartTask() {
        Task { [weak self] in
            guard let self, let voiceSession else { return }
            do {
                let request = try await voiceSession.end()
                dispatch(.finalTranscript(request.transcript))
                startSidecarExchange(request)
            } catch VoiceSessionError.cancelled {
                // stop already handled by the state machine
            } catch {
                dispatch(.taskFailed(reason: "No speech captured. Try again closer to the microphone."))
            }
            self.voiceSession = nil
        }
    }

    private func cancelCapture() {
        let session = voiceSession
        voiceSession = nil
        Task { await session?.cancel() }
    }

    // MARK: Sidecar exchange

    private func startSidecarExchange(_ request: VoiceRequest) {
        let client = SidecarClient(agentProjectURL: Self.agentProjectURL)
        sidecarClient = client
        let taskID = UUID()

        sidecarTask = Task { [weak self] in
            do {
                let events = try await client.start()
                try await client.send(
                    Envelope(type: .voiceFinal, taskID: taskID, payload: .voiceFinal(request)))
                for try await envelope in events {
                    guard envelope.taskID == taskID else { continue }
                    switch envelope.payload {
                    case .planReady(let plan):
                        self?.dispatch(.planReady(summary: plan.summary))
                    case .taskCompleted(let completed):
                        self?.dispatch(.taskCompleted(state: completed.state, summary: completed.summary))
                        await client.cancel()
                        return
                    case .taskFailed(let failure):
                        self?.dispatch(.taskFailed(reason: failure.error.message))
                        await client.cancel()
                        return
                    default:
                        continue
                    }
                }
                self?.dispatch(.taskFailed(reason: "The agent exited before completing the task."))
            } catch {
                if !Task.isCancelled {
                    self?.dispatch(.taskFailed(reason: error.localizedDescription))
                }
            }
            await client.cancel()
        }
    }

    private func cancelSidecar() {
        sidecarTask?.cancel()
        sidecarTask = nil
        let client = sidecarClient
        sidecarClient = nil
        Task { await client?.cancel() }
    }
}
