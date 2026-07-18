import AppKit
import Foundation
import SwiftUI
import VoiceOpsCore

/// Owns the session: hotkey → capture → sidecar exchange → companion state.
/// All state changes flow through SessionStateMachine.reduce; this class only
/// runs the side effects for transitions the machine has already approved.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var permissionSettingsURL: URL?
    @Published private(set) var groundingChips: [GroundingChip] = []
    @Published private(set) var groundingAdapter: GroundingAdapterKind?
    @Published private(set) var groundingWarnings: [String] = []
    @Published private(set) var verificationResults: [VerificationResult] = []
    @Published private(set) var taskTrace = TaskTrace()
    @Published private(set) var activeTaskSpec: VersionedTaskSpec?
    @Published private(set) var appliedPlanPatch: AppliedPlanPatch?
    @Published private(set) var executionLedger: [ExecutionLedgerEvent] = []
    @Published private(set) var voiceProvider = "Apple Speech"
    @Published private(set) var voiceModel = "On-device/system fallback"
    @Published private(set) var voiceFallbackActive = false
    @Published private(set) var voiceStatus = "LIVE"
    @Published private(set) var agentTranscript = ""
    @Published private(set) var pendingConversationApproval: ConversationApprovalCard?

    private let narrator = Narrator()
    private var hotKey: HotKeyManager?
    private var panicStop: PanicStopMonitor?
    private var panel: CompanionPanelController?
    private var voiceSession: VoiceSessionController?
    private var conversationSession: RealtimeConversationSession?
    private var sidecarClient: SidecarClient?
    private var sidecarTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private let screenContextCollector: any ScreenContextCollecting = NativeScreenContextCollector()
    private let reminderWorkflow = EventKitReminderWorkflow()
    private let meetingBriefingWorkflow = EventKitMeetingBriefingWorkflow()
    private let researchFollowupWorkflow = ResearchFollowupWorkflow()
    private var activeScreenContext: CollectedScreenContext?
    private var attemptLedger = ActionAttemptLedger()
    private var cachedActions: [String: ActionResult] = [:]
    private var activeTaskID: UUID?
    private var conversationTaskActive = false
    private var microphonePermissionGranted = false
    private var isReplayingOrderRescue = false
    private var replayReportURL: URL?
    private var replayScreenshotURL: URL?

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
        replayReportURL = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--replay-report=") })
            .map { URL(fileURLWithPath: String($0.dropFirst("--replay-report=".count))) }
        replayScreenshotURL = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--replay-screenshot=") })
            .map { URL(fileURLWithPath: String($0.dropFirst("--replay-screenshot=".count))) }
        hotKey = HotKeyManager { [weak self] in self?.toggle() }
        panicStop = PanicStopMonitor { [weak self] in self?.stop() }
        panel = CompanionPanelController(coordinator: self)
        if ProcessInfo.processInfo.arguments.contains("--replay-order-rescue") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.replayOrderRescueDemo()
            }
        }
    }

    func toggle() {
        switch state {
        case .idle where ConversationModePolicy.shouldOpen(
            preferenceEnabled: conversationalVoiceEnabled,
            credentialAvailable: loadOpenAIApiKey() != nil):
            dispatch(.conversationOpened)
        case .conversing:
            endConversationSession(label: "CLOSED")
        default:
            dispatch(.hotkeyTapped)
        }
    }
    func stop() {
        resolveApproval(false)
        dispatch(.stopRequested)
    }
    func approvePendingAction() {
        if let approval = pendingConversationApproval {
            pendingConversationApproval = nil
            sendConversationTool(
                name: "confirm_approval",
                arguments: approval.confirmationArguments,
                callID: "ui-confirm-\(UUID().uuidString.lowercased())")
            return
        }
        guard case .awaitingApproval = state else { return }
        let continuation = approvalContinuation
        approvalContinuation = nil
        dispatch(.approvalGranted)
        continuation?.resume(returning: true)
    }
    func denyPendingAction() {
        if pendingConversationApproval != nil {
            pendingConversationApproval = nil
            recordTrace(.approval, "Spoken approval declined; no action was authorized")
            return
        }
        guard case .awaitingApproval = state else { return }
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: false)
        dispatch(.approvalDenied)
    }
    func dismiss() { dispatch(.dismissResult) }
    func replayOrderRescueDemo() {
        guard state == .idle else { return }
        isReplayingOrderRescue = true
        voiceProvider = "Deterministic Replay"
        voiceModel = "Canonical Order Rescue transcripts"
        voiceFallbackActive = true
        voiceStatus = "REPLAY"

        dispatch(.hotkeyTapped)
        dispatch(.partialTranscript(OrderRescueDemo.initialRequest))
        dispatch(.hotkeyTapped)

        do {
            let context = try loadOrderRescueReplayContext()
            activeScreenContext = context
            startSidecarExchange(
                VoiceRequest(
                    transcript: OrderRescueDemo.initialRequest,
                    locale: "en-US",
                    confidence: 1,
                    segments: []),
                context: context)
        } catch {
            dispatch(.taskFailed(reason:
                "The tested Order Rescue replay could not load: "
                    + error.localizedDescription))
        }
    }
    func openPermissionSettings() {
        guard let permissionSettingsURL else { return }
        NSWorkspace.shared.open(permissionSettingsURL)
    }

    func dispatch(_ event: SessionEvent) {
        guard let next = SessionStateMachine.reduce(state, event) else { return }
        let previous = state
        state = next
        panicStop?.setArmed(isTaskActive(next))
        runEffects(from: previous, event: event, to: next)
    }

    private func runEffects(from previous: SessionState, event: SessionEvent, to state: SessionState) {
        switch state {
        case .idle:
            if case .listening = previous { cancelCapture() }
            if case .conversing = previous {
                cancelConversationAudio()
                cancelSidecar()
            }
            cleanupScreenContext()
            panel?.hide()

        case .listening:
            // Partial transcript events stay in `.listening`. Only the initial
            // idle -> listening transition may reset the session and install
            // an audio tap; otherwise every partial would start another
            // VoiceSessionController on the same AVAudioEngine input.
            switch previous {
            case .idle, .conversing: break
            default: return
            }
            taskTrace = TaskTrace()
            recordTrace(.listening, "Voice capture started")
            permissionSettingsURL = nil
            groundingChips = []
            groundingAdapter = nil
            groundingWarnings = []
            verificationResults = []
            activeTaskSpec = nil
            appliedPlanPatch = nil
            executionLedger = []
            pendingConversationApproval = nil
            agentTranscript = ""
            cleanupScreenContext()
            panel?.show()
            // Never play synthesized speech while the microphone is open; it
            // contaminates recognition and makes interruption behavior flaky.
            if !isReplayingOrderRescue { startCapture() }

        case .grounding:
            recordTrace(.grounding, "Collecting task-scoped screen context")
            if case .listening = previous {
                narrate("Got it")
                if !isReplayingOrderRescue { finishCaptureAndCollectContext() }
            }

        case .planning:
            recordTrace(.planning, "Grounded context sent to the typed planner")
            narrate("I found the visible context")

        case .readyForCorrection(_, let version, _):
            recordTrace(.planning, "Version \(version) is ready for a voice correction")
            narrate("Plan ready")

        case .correctionListening:
            guard case .readyForCorrection = previous else { return }
            recordTrace(.listening, "Voice correction capture started on the active task")
            if !isReplayingOrderRescue { startCapture() }

        case .awaitingApproval:
            recordTrace(.approval, "Waiting for explicit schedule approval")
            narrate("Approval needed")

        case .acting:
            recordTrace(.action, "Approved plan entered native execution")
            if case .correctionListening = previous {
                if isReplayingOrderRescue {
                    sendOrderRescueReplayCorrection()
                } else {
                    finishCorrectionCapture()
                }
            } else {
                narrate("Working on it")
            }

        case .verifying:
            recordTrace(.verification, "Independent fetch-back verification started")
            narrate("Verifying")

        case .conversing:
            // The speech-to-speech session owns audio in this state; the
            // session lifecycle (WebSocket + engine) is wired by the
            // conversation controller, which dispatches these events.
            guard case .idle = previous else { return }
            taskTrace = TaskTrace()
            recordTrace(.listening, "Conversational voice session opened")
            permissionSettingsURL = nil
            groundingChips = []
            groundingAdapter = nil
            groundingWarnings = []
            verificationResults = []
            activeTaskSpec = nil
            appliedPlanPatch = nil
            executionLedger = []
            pendingConversationApproval = nil
            agentTranscript = ""
            cleanupScreenContext()
            panel?.show()
            startConversationSession()

        case .result(let result):
            let shouldExitAfterReplay = isReplayingOrderRescue && replayReportURL != nil
            switch result {
            case .completed(let taskState, _):
                recordTrace(.outcome, "Task finished: \(taskState.rawValue)")
            case .failed:
                recordTrace(.outcome, "Task failed closed")
            case .cancelled:
                recordTrace(.outcome, "Panic stop cancelled remaining work")
            }
            switch result {
            case .completed(let state, _):
                switch state {
                case .succeeded: narrate("Done")
                case .partial: narrate("Partially completed")
                case .failed: narrate("Verification failed")
                case .needsUser: narrate("I need one detail")
                }
            case .failed: narrate("That didn't work")
            case .cancelled: narrate("Stopped")
            }
            cancelCapture()
            cancelConversationAudio()
            contextTask?.cancel()
            contextTask = nil
            writeOrderRescueReplayReport(result)
            writeOrderRescueReplayScreenshot()
            cancelSidecar()
            cleanupScreenContext()
            if shouldExitAfterReplay {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: Conversational voice

    private var conversationalVoiceEnabled: Bool {
        UserDefaults.standard.object(
            forKey: VLMConfiguration.conversationalVoiceDefaultsKey) as? Bool ?? true
    }

    private func startConversationSession() {
        sidecarTask = Task { [weak self] in
            guard let self, let apiKey = loadOpenAIApiKey() else {
                self?.handleConversationFailure(VLMCredentialError.invalidCredential)
                return
            }
            if !microphonePermissionGranted {
                microphonePermissionGranted = await SpeechTranscriber
                    .requestMicrophonePermission()
            }
            guard microphonePermissionGranted, case .conversing = state else {
                handleConversationFailure(SpeechTranscriber.SpeechError.microphoneDenied)
                return
            }

            let taskID = UUID()
            let context: CollectedScreenContext
            do {
                recordTrace(.grounding, "Collecting live screen context before conversation")
                context = try await screenContextCollector.collect()
            } catch let error as ScreenContextError {
                permissionSettingsURL = error.settingsURL
                dispatch(.taskFailed(reason: error.localizedDescription))
                return
            } catch {
                dispatch(.taskFailed(reason:
                    "Could not collect the live screen before conversation: "
                        + error.localizedDescription))
                return
            }
            guard !Task.isCancelled, case .conversing = state else {
                await screenContextCollector.cleanup(
                    captureID: context.observation.captureID)
                return
            }
            activeScreenContext = context

            let client = SidecarClient(
                agentProjectURL: Self.agentProjectURL,
                additionalEnvironment: sidecarEnvironment())
            let session = RealtimeConversationSession(
                apiKey: apiKey,
                taskID: taskID,
                sidecar: client,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in self?.handleConversationEvent(event) }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor [weak self] in self?.handleConversationFailure(error) }
                })
            sidecarClient = client
            activeTaskID = taskID
            conversationTaskActive = true
            conversationSession = session
            do {
                let events = try await client.start()
                try await client.send(Envelope(
                    type: .observationReady,
                    taskID: taskID,
                    payload: .observationReady(context.observation)))
                try await session.start()
                voiceProvider = "OpenAI Realtime Conversation"
                voiceModel = "gpt-realtime · marin · semantic VAD"
                voiceFallbackActive = false
                voiceStatus = "LIVE"
                recordTrace(.listening, "S2S session ready with echo-cancelled barge-in")

                for try await envelope in events {
                    guard envelope.taskID == taskID else { continue }
                    if await handleConversationEnvelope(envelope, client: client) {
                        return
                    }
                }
                if !Task.isCancelled {
                    dispatch(.taskFailed(reason:
                        "The agent exited before the conversation completed."))
                }
            } catch is CancellationError {
                // Panic stop or intentional close owns the visible transition.
            } catch {
                if !Task.isCancelled { handleConversationFailure(error) }
            }
        }
    }

    private func handleConversationEvent(_ event: RealtimeConversationServerEvent) {
        switch event {
        case .sessionReady:
            voiceStatus = "LIVE"
        case .userSpeechStarted:
            dispatch(.agentSpeechEnded)
            recordTrace(.listening, "Barge-in stopped agent playback")
        case .userTranscript(let transcript):
            dispatch(.partialTranscript(transcript))
        case .agentTranscriptDelta(let delta):
            if case .conversing(let speaking, _, _) = state, !speaking {
                agentTranscript = ""
            }
            agentTranscript += delta
            dispatch(.agentSpeechStarted)
        case .audioDelta:
            if case .conversing(let speaking, _, _) = state, !speaking {
                agentTranscript = ""
            }
            dispatch(.agentSpeechStarted)
        case .responseDone:
            dispatch(.agentSpeechEnded)
        case .functionCall(_, let name, _):
            recordTrace(.planning, "Realtime requested typed tool \(name)")
        case .error(let message):
            handleConversationFailure(
                RealtimeConversationSession.SessionError.server(message))
        case .ignored:
            break
        }
    }

    private func handleConversationEnvelope(
        _ envelope: Envelope, client: SidecarClient
    ) async -> Bool {
        switch envelope.payload {
        case .groundingReady(let grounding):
            guard let observation = activeScreenContext?.observation else {
                dispatch(.taskFailed(reason:
                    "Grounding evidence arrived without its live screen capture."))
                await client.cancel()
                return true
            }
            presentGrounding(grounding, observation: observation, transition: false)
        case .taskSpecReady(let task):
            activeTaskSpec = task
            recordTrace(.planning, "Compiled persistent Order Rescue task version \(task.version)")
            dispatch(.taskSpecReady(version: task.version, objective: task.objective))
        case .planPatchApplied(let patch):
            appliedPlanPatch = patch
            recordTrace(
                .planning,
                "Applied plan patch v\(patch.baseVersion) → v\(patch.newVersion)")
        case .approvalRequested(let request):
            do {
                pendingConversationApproval = try ConversationApprovalCard(request: request)
                recordTrace(.approval, "Read-back binding is waiting for spoken or click confirmation")
            } catch {
                dispatch(.taskFailed(reason: "The approval binding was malformed; nothing was authorized."))
                return true
            }
        case .ledgerEvent(let event):
            executionLedger.append(event)
            recordTrace(traceStage(for: event.eventType), "\(event.eventType.rawValue.capitalized): \(event.what)")
        case .conversationToolResult(let result):
            try? await conversationSession?.accept(result)
            if result.callID.hasPrefix("ui-confirm-") && result.status == "ok" {
                sendConversationTool(
                    name: "execute_plan", arguments: [:],
                    callID: "ui-execute-\(UUID().uuidString.lowercased())")
            } else if result.callID.hasPrefix("fallback-patch-") && result.status == "ok" {
                sendConversationTool(
                    name: "request_approval", arguments: [:],
                    callID: "fallback-approval-\(UUID().uuidString.lowercased())")
            }
        case .planReady(let plan):
            await executeConversationNativePlan(plan, client: client)
        case .taskCompleted(let completed):
            verificationResults = completed.verification
            pendingConversationApproval = nil
            dispatch(.taskCompleted(state: completed.state, summary: completed.summary))
            await client.cancel()
            return true
        case .taskFailed(let failure):
            dispatch(.taskFailed(reason: failure.error.message))
            await client.cancel()
            return true
        default:
            break
        }
        return false
    }

    private func presentGrounding(
        _ grounding: GroundingResult,
        observation: Observation,
        transition: Bool
    ) {
        let chips = grounding.references.compactMap {
            GroundingChip(reference: $0, candidates: observation.elements)
        }
        groundingChips = chips
        groundingAdapter = grounding.adapter
        groundingWarnings = grounding.warnings
        recordTrace(
            .grounding,
            "Grounded \(chips.count) live screen reference"
                + (chips.count == 1 ? "" : "s")
                + " with \(grounding.adapter.rawValue)")
        if transition {
            dispatch(.groundingReady(chips))
        }
    }

    private func handleConversationFailure(_ error: Error) {
        guard case .conversing = state else { return }
        cancelConversationAudio()
        let fallback = ConversationFallbackPresentation(reason: error.localizedDescription)
        voiceProvider = fallback.provider
        voiceModel = "System recognizer · task-preserving fallback"
        voiceFallbackActive = true
        voiceStatus = fallback.status
        recordTrace(.recovery, fallback.detail)
        let hasTask = activeTaskSpec != nil
        if !hasTask { cancelSidecar() }
        dispatch(.conversationFallback(objective: activeTaskSpec?.objective))
    }

    private func endConversationSession(label: String) {
        cancelConversationAudio()
        voiceStatus = label
        if activeTaskSpec == nil { cancelSidecar() }
        dispatch(.conversationFallback(objective: activeTaskSpec?.objective))
    }

    private func cancelConversationAudio() {
        conversationSession?.cancel()
        conversationSession = nil
    }

    private func sendConversationTool(
        name: String, arguments: [String: JSONValue], callID: String
    ) {
        guard let client = sidecarClient, let taskID = activeTaskID else { return }
        if let session = conversationSession {
            Task {
                do { try await session.sendTool(name: name, arguments: arguments, callID: callID) }
                catch { await MainActor.run { self.handleConversationFailure(error) } }
            }
            return
        }
        let bridge = ConversationToolBridge(taskID: taskID)
        let json = (try? JSONEncoder().encode(arguments)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
        guard case .success(let envelope) = bridge.envelope(for: (callID, name, json))
        else { return }
        Task {
            do { try await client.send(envelope) }
            catch { await MainActor.run { self.dispatch(.taskFailed(reason: error.localizedDescription)) } }
        }
    }

    private func executeConversationNativePlan(
        _ plan: TaskPlan, client: SidecarClient
    ) async {
        guard let step = plan.steps.first, let taskID = activeTaskID else { return }
        guard let action = await executeNativeStep(step, taskID: taskID) else { return }
        do {
            try await client.send(Envelope(
                type: .actionFinished, taskID: taskID,
                payload: .actionFinished(action)))
            guard action.status == .executed else { return }
            dispatch(.verificationStarted)
            let verifications = step.tool == "reminders.create"
                ? reminderWorkflow.verify(step: step, action: action) : []
            for verification in verifications {
                try await client.send(Envelope(
                    type: .verificationFinished, taskID: taskID,
                    payload: .verificationFinished(verification)))
            }
        } catch {
            dispatch(.taskFailed(reason:
                "The native reminder result could not reach the verifier: "
                    + error.localizedDescription))
        }
    }

    // MARK: Capture

    private func startCapture() {
        Task { [weak self] in
            guard let self else { return }
            if !microphonePermissionGranted {
                microphonePermissionGranted = await SpeechTranscriber
                    .requestMicrophonePermission()
            }
            guard microphonePermissionGranted else {
                dispatch(.taskFailed(reason:
                    "Microphone permission is missing. Enable VoiceOps in "
                    + "System Settings → Privacy & Security → Microphone."))
                return
            }
            // The user may have cancelled while the permission dialog was up.
            guard isVoiceCaptureState(state) else { return }

            let locale = Locale.current.identifier(.bcp47)
            let speechFallbackAuthorized = await SpeechTranscriber
                .requestSpeechPermission()
            guard isVoiceCaptureState(state) else { return }
            if let apiKey = loadOpenAIApiKey() {
                let realtime = OpenAIRealtimeTranscriber(
                    apiKey: apiKey,
                    configuration: .init(
                        model: "gpt-realtime-whisper",
                        language: Locale.current.language.languageCode?.identifier ?? "en",
                        delay: .medium)
                ) { [weak self] outcome in
                    Task { @MainActor [weak self] in
                        self?.voiceFinalizationCompleted(outcome)
                    }
                }
                let transcriber: any Transcriber
                if speechFallbackAuthorized {
                    transcriber = FailoverTranscriber(
                        primary: realtime,
                        fallback: SpeechTranscriber()
                    ) { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.voiceProvider = "Apple Speech"
                            self.voiceModel = "System recognizer · automatic fallback"
                            self.voiceFallbackActive = true
                            self.voiceStatus = "FALLBACK"
                            self.recordTrace(
                                .recovery,
                                "Voice provider failed over without restarting the task: "
                                    + error.localizedDescription)
                        }
                    }
                } else {
                    transcriber = realtime
                }
                let controller = VoiceSessionController(
                    transcriber: transcriber,
                    locale: locale,
                    finalizationTimeout: .seconds(8))
                configureVoiceCallbacks(controller)
                voiceSession = controller
                voiceProvider = "OpenAI Realtime"
                voiceModel = "gpt-realtime-whisper → gpt-4o-transcribe"
                voiceFallbackActive = false
                voiceStatus = "LIVE"
                do {
                    try await controller.begin()
                    recordTrace(.listening, "OpenAI Realtime transcription connected")
                    return
                } catch {
                    dispatch(.taskFailed(reason:
                        "Neither configured voice provider could start: "
                            + error.localizedDescription))
                    return
                }
            }

            guard speechFallbackAuthorized else {
                dispatch(.taskFailed(reason:
                    "Speech Recognition permission is disabled. Enable it in "
                    + "System Settings → Privacy & Security."))
                return
            }
            guard isVoiceCaptureState(state) else { return }
            let controller = VoiceSessionController(
                transcriber: SpeechTranscriber(), locale: locale)
            configureVoiceCallbacks(controller)
            voiceSession = controller
            voiceProvider = "Apple Speech"
            voiceModel = "System recognizer · automatic fallback"
            voiceFallbackActive = loadOpenAIApiKey() != nil
            voiceStatus = voiceFallbackActive ? "FALLBACK" : "LIVE"
            do {
                try await controller.begin()
                recordTrace(
                    .listening,
                    voiceFallbackActive
                        ? "Apple Speech fallback is active"
                        : "Apple Speech transcription started")
            } catch {
                dispatch(.taskFailed(reason:
                    "Could not start audio capture: \(error.localizedDescription)"))
            }
        }
    }

    private func configureVoiceCallbacks(_ controller: VoiceSessionController) {
        controller.onPartial = { [weak self] in self?.dispatch(.partialTranscript($0)) }
        controller.onAutoFinal = { [weak self] in self?.dispatch(.finalTranscript($0)) }
        controller.onError = { [weak self] in
            self?.dispatch(.taskFailed(reason: "Speech capture failed: \($0.localizedDescription)"))
        }
        controller.onFinalizationTimeout = { [weak self] in
            guard let self else { return }
            if self.voiceProvider == "OpenAI Realtime" {
                self.voiceModel = "gpt-realtime-whisper · retained live partial"
            }
            self.voiceStatus = "RECOVERED"
            self.recordTrace(
                .recovery,
                "Voice finalization timed out; retained the last visible live transcript")
        }
    }

    private func markVoiceFinalizing() {
        guard voiceProvider == "OpenAI Realtime" else { return }
        voiceStatus = "FINALIZING"
        recordTrace(
            .listening,
            "Realtime capture committed; refining the complete utterance within a five-second budget")
    }

    private func voiceFinalizationCompleted(_ outcome: OpenAIFinalizationOutcome) {
        guard voiceProvider == "OpenAI Realtime" else { return }
        switch outcome {
        case .refined(let model):
            voiceModel = "\(model) · complete utterance"
            voiceStatus = "REFINED"
            recordTrace(
                .listening,
                "Voice final refined by \(model); the completed Realtime result remained the fail-safe")
        case .realtimeFallback(let model):
            voiceModel = "\(model) · retained final"
            voiceStatus = "RECOVERED"
            recordTrace(
                .recovery,
                "Final refinement was unavailable; retained the completed \(model) transcript")
        }
    }

    private func finishCaptureAndCollectContext() {
        contextTask = Task { [weak self] in
            guard let self, let voiceSession else { return }
            do {
                markVoiceFinalizing()
                let request = try await voiceSession.end()
                dispatch(.finalTranscript(request.transcript))
                let context = try await screenContextCollector.collect()
                guard !Task.isCancelled, case .grounding = state else {
                    await screenContextCollector.cleanup(
                        captureID: context.observation.captureID)
                    return
                }
                activeScreenContext = context
                startSidecarExchange(request, context: context)
            } catch VoiceSessionError.cancelled {
                // stop already handled by the state machine
            } catch VoiceSessionError.noSpeech {
                dispatch(.taskFailed(reason:
                    "No speech captured. Try again closer to the microphone."))
            } catch let error as ScreenContextError {
                permissionSettingsURL = error.settingsURL
                dispatch(.taskFailed(reason: error.localizedDescription))
            } catch {
                if !Task.isCancelled {
                    dispatch(.taskFailed(reason:
                        "Could not collect the spoken request and visible screen: "
                        + error.localizedDescription))
                }
            }
            self.voiceSession = nil
            self.contextTask = nil
        }
    }

    private func finishCorrectionCapture() {
        contextTask = Task { [weak self] in
            guard let self,
                  let voiceSession,
                  let client = sidecarClient,
                  let taskID = activeTaskID
            else { return }
            do {
                markVoiceFinalizing()
                let correction = try await voiceSession.end()
                guard !Task.isCancelled else { return }
                recordTrace(
                    .planning,
                    "Correction transcribed and sent as a patch to task \(taskID.uuidString.prefix(8))")
                if conversationTaskActive {
                    let bridge = ConversationToolBridge(taskID: taskID)
                    let arguments: [String: JSONValue] = [
                        "transcript": .string(correction.transcript)
                    ]
                    let data = try JSONEncoder().encode(arguments)
                    let callID = "fallback-patch-\(UUID().uuidString.lowercased())"
                    guard case .success(let envelope) = bridge.envelope(for: (
                        callID, "apply_patch", String(decoding: data, as: UTF8.self)))
                    else { throw SidecarError.notRunning }
                    try await client.send(envelope)
                } else {
                    try await client.send(Envelope(
                        type: .voiceCorrection,
                        taskID: taskID,
                        payload: .voiceCorrection(correction)))
                }
            } catch VoiceSessionError.cancelled {
                // stop already handled by the state machine
            } catch VoiceSessionError.noSpeech {
                dispatch(.taskFailed(reason:
                    "No correction speech captured. The version-one plan was not changed."))
            } catch {
                if !Task.isCancelled {
                    dispatch(.taskFailed(reason:
                        "Could not apply the voice correction: \(error.localizedDescription)"))
                }
            }
            self.voiceSession = nil
            self.contextTask = nil
        }
    }

    private func cancelCapture() {
        let session = voiceSession
        voiceSession = nil
        Task { await session?.cancel() }
    }

    // MARK: Sidecar exchange

    private func startSidecarExchange(
        _ request: VoiceRequest, context: CollectedScreenContext
    ) {
        let client = SidecarClient(
            agentProjectURL: Self.agentProjectURL,
            additionalEnvironment: sidecarVLMEnvironment())
        sidecarClient = client
        let taskID = UUID()
        activeTaskID = taskID

        sidecarTask = Task { [weak self] in
            do {
                let events = try await client.start()
                try await client.send(
                    Envelope(
                        type: .observationReady,
                        taskID: taskID,
                        payload: .observationReady(context.observation)))
                try await client.send(
                    Envelope(type: .voiceFinal, taskID: taskID, payload: .voiceFinal(request)))
                for try await envelope in events {
                    guard envelope.taskID == taskID else { continue }
                    switch envelope.payload {
                    case .groundingReady(let grounding):
                        self?.presentGrounding(
                            grounding,
                            observation: context.observation,
                            transition: true)
                    case .planReady(let plan):
                        if let step = plan.steps.first, let self {
                            if step.requiresConfirmation {
                                dispatch(.approvalRequested(description: step.description))
                                let approved = await waitForApproval()
                                guard approved, !Task.isCancelled else {
                                    await client.cancel()
                                    return
                                }
                            } else {
                                dispatch(.planReady(summary: plan.summary))
                            }
                            guard let action = await executeNativeStep(
                                step, taskID: taskID)
                            else { continue }
                            if case .string(let rawURL)? = action.rawResult["settings_url"] {
                                permissionSettingsURL = URL(string: rawURL)
                            }
                            try await client.send(Envelope(
                                type: .actionFinished,
                                taskID: taskID,
                                payload: .actionFinished(action)))
                            if action.status == .executed {
                                dispatch(.verificationStarted)
                                let verifications: [VerificationResult]
                                switch step.tool {
                                case "reminders.create":
                                    verifications = reminderWorkflow.verify(
                                        step: step, action: action)
                                case "notes.create_meeting_brief":
                                    verifications = meetingBriefingWorkflow.verify(
                                        step: step, action: action)
                                case "research.create_note_and_followups":
                                    verifications = researchFollowupWorkflow.verify(
                                        step: step, action: action)
                                default:
                                    verifications = []
                                }
                                for verification in verifications {
                                    try await client.send(Envelope(
                                        type: .verificationFinished,
                                        taskID: taskID,
                                        payload: .verificationFinished(verification)))
                                }
                            }
                        }
                    case .taskSpecReady(let task):
                        self?.activeTaskSpec = task
                        self?.recordTrace(
                            .planning,
                            "Compiled persistent Order Rescue task version \(task.version)")
                        self?.dispatch(.taskSpecReady(
                            version: task.version, objective: task.objective))
                        if task.version == 1, self?.isReplayingOrderRescue == true {
                            self?.scheduleOrderRescueReplayCorrection()
                        }
                    case .planPatchApplied(let patch):
                        self?.appliedPlanPatch = patch
                        self?.recordTrace(
                            .planning,
                            "Applied plan patch v\(patch.baseVersion) → v\(patch.newVersion): "
                                + "\(patch.removed.count) removed, \(patch.added.count) added")
                    case .ledgerEvent(let event):
                        self?.executionLedger.append(event)
                        self?.recordTrace(
                            self?.traceStage(for: event.eventType) ?? .planning,
                            "\(event.eventType.rawValue.capitalized): \(event.what)")
                    case .taskCompleted(let completed):
                        self?.verificationResults = completed.verification
                        self?.dispatch(.taskCompleted(state: completed.state, summary: completed.summary))
                        await client.cancel()
                        return
                    case .taskFailed(let failure):
                        if case .string(let rawURL)? = failure.error.details["settings_url"] {
                            self?.permissionSettingsURL = URL(string: rawURL)
                        }
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

    private func executeNativeStep(
        _ step: TaskStep, taskID: UUID
    ) async -> ActionResult? {
        let cacheKey = "\(taskID.uuidString):\(step.id)"
        while !Task.isCancelled {
            let claim = attemptLedger.claim(
                taskID: taskID, stepID: step.id,
                maxAttempts: step.maxAttempts)
            let attempt: Int
            switch claim {
            case .allowed(let value):
                attempt = value
            case .rejectedCompleted:
                recordTrace(.recovery, "Duplicate completed action suppressed")
                return cachedActions[cacheKey]
            case .rejectedUncertain:
                recordTrace(.recovery, "Duplicate uncertain action suppressed")
                return cachedActions[cacheKey]
            case .rejectedBudget:
                recordTrace(.recovery, "Recovery budget exhausted before another write")
                return cachedActions[cacheKey]
            }

            recordTrace(
                .action,
                "Attempt \(attempt)/\(max(1, step.maxAttempts)) via \(step.tool)")
            guard let action = await performNativeStep(step) else { return nil }
            attemptLedger.finish(
                taskID: taskID, stepID: step.id, status: action.status)
            cachedActions[cacheKey] = action
            let duration = max(0, Int(
                action.endedAt.timeIntervalSince(action.startedAt) * 1_000))
            recordTrace(
                .action,
                "\(action.channel) returned \(action.status.rawValue) in \(duration) ms")

            let recovery = RecoveryPolicy.decide(
                status: action.status, error: action.error, risk: step.risk,
                attempt: attempt, maxAttempts: step.maxAttempts)
            switch recovery {
            case .complete:
                return action
            case .requestPermission(let settingsURL):
                if let settingsURL { permissionSettingsURL = URL(string: settingsURL) }
                recordTrace(.recovery, "Permission recovery requires the user")
                return action
            case .verifyWithoutRetry(let reason):
                recordTrace(.recovery, reason)
                return action
            case .stop(let reason):
                recordTrace(.recovery, reason)
                return action
            case .retrySameTarget(let reason):
                recordTrace(.recovery, reason)
            case .reobserveAndRetry(let reason):
                recordTrace(.recovery, reason)
                await refreshContextForRecovery()
            case .openAppAndRetry(let reason):
                recordTrace(.recovery, reason)
                await openRequiredApplication(for: step)
                await refreshContextForRecovery()
            }
        }
        return cachedActions[cacheKey]
    }

    private func performNativeStep(_ step: TaskStep) async -> ActionResult? {
        switch step.tool {
        case "reminders.create":
            await reminderWorkflow.execute(step: step)
        case "notes.create_meeting_brief":
            await meetingBriefingWorkflow.execute(step: step)
        case "research.create_note_and_followups":
            await researchFollowupWorkflow.execute(step: step)
        default:
            nil
        }
    }

    private func refreshContextForRecovery() async {
        do {
            let refreshed = try await screenContextCollector.collect()
            recordTrace(
                .recovery,
                "Re-observed \(refreshed.observation.activeApp.name) before retry")
            await screenContextCollector.cleanup(
                captureID: refreshed.observation.captureID)
        } catch {
            recordTrace(.recovery, "Re-observation failed: \(error.localizedDescription)")
        }
    }

    private func openRequiredApplication(for step: TaskStep) async {
        let bundleID: String?
        switch step.tool {
        case "reminders.create", "research.create_note_and_followups":
            bundleID = "com.apple.reminders"
        case "notes.create_meeting_brief":
            bundleID = "com.apple.Notes"
        default:
            bundleID = nil
        }
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(
                at: url, configuration: configuration
            ) { _, _ in continuation.resume() }
        }
    }

    private func cancelSidecar() {
        resolveApproval(false)
        replayTask?.cancel()
        replayTask = nil
        sidecarTask?.cancel()
        sidecarTask = nil
        let client = sidecarClient
        sidecarClient = nil
        if let taskID = activeTaskID {
            attemptLedger.remove(taskID: taskID)
            let prefix = taskID.uuidString + ":"
            cachedActions = cachedActions.filter { !$0.key.hasPrefix(prefix) }
        }
        activeTaskID = nil
        conversationTaskActive = false
        pendingConversationApproval = nil
        isReplayingOrderRescue = false
        Task { await client?.cancel() }
    }

    private func waitForApproval() async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    private func resolveApproval(_ approved: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func recordTrace(_ stage: TaskTraceStage, _ message: String) {
        var trace = taskTrace
        trace.record(stage, message)
        taskTrace = trace
    }

    private func narrate(_ message: String) {
        if !isReplayingOrderRescue { narrator.say(message) }
    }

    private func scheduleOrderRescueReplayCorrection() {
        guard replayTask == nil else { return }
        replayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self,
                  case .readyForCorrection = state,
                  isReplayingOrderRescue
            else { return }
            dispatch(.hotkeyTapped)
            dispatch(.partialTranscript(OrderRescueDemo.correction))
            dispatch(.hotkeyTapped)
        }
    }

    private func sendOrderRescueReplayCorrection() {
        guard let client = sidecarClient, let taskID = activeTaskID else {
            dispatch(.taskFailed(reason: "The replay lost its active task before correction."))
            return
        }
        replayTask = Task { [weak self] in
            do {
                try await client.send(Envelope(
                    type: .voiceCorrection,
                    taskID: taskID,
                    payload: .voiceCorrection(VoiceRequest(
                        transcript: OrderRescueDemo.correction,
                        locale: "en-US",
                        confidence: 1,
                        segments: []))))
            } catch {
                if !Task.isCancelled {
                    self?.dispatch(.taskFailed(reason:
                        "The replay correction failed: " + error.localizedDescription))
                }
            }
        }
    }

    private func loadOrderRescueReplayContext() throws -> CollectedScreenContext {
        let fixtureURL = Self.agentProjectURL
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/screen/order_1842_observation.json")
        let observation = try JSONDecoder().decode(
            Observation.self, from: Data(contentsOf: fixtureURL))
        return CollectedScreenContext(
            observation: observation,
            screenshotFileURL: fixtureURL)
    }

    private func writeOrderRescueReplayReport(_ result: SessionResult) {
        guard isReplayingOrderRescue, let replayReportURL else { return }
        let terminalState: String
        let summary: String
        switch result {
        case .completed(let state, let resultSummary):
            terminalState = state.rawValue
            summary = resultSummary
        case .failed(let reason):
            terminalState = "failed"
            summary = reason
        case .cancelled:
            terminalState = "cancelled"
            summary = "Replay cancelled"
        }
        let report: [String: Any] = [
            "mode": "deterministic_replay",
            "terminal_state": terminalState,
            "summary": summary,
            "task_id": activeTaskID.map { $0.uuidString as Any } ?? NSNull(),
            "task_version": activeTaskSpec.map { $0.version as Any } ?? NSNull(),
            "patch": [
                "base_version": appliedPlanPatch.map { $0.baseVersion as Any } ?? NSNull(),
                "new_version": appliedPlanPatch.map { $0.newVersion as Any } ?? NSNull(),
                "added": appliedPlanPatch?.added ?? [],
                "removed": appliedPlanPatch?.removed ?? [],
                "preserved_count": appliedPlanPatch?.preserved.count ?? 0,
            ],
            "ledger": executionLedger.map {
                [
                    "sequence": $0.sequence,
                    "event_type": $0.eventType.rawValue,
                    "what": $0.what,
                    "source": $0.source,
                ] as [String: Any]
            },
            "verification": verificationResults.map {
                [
                    "predicate_id": $0.predicateId,
                    "passed": $0.passed,
                ] as [String: Any]
            },
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: replayReportURL, options: .atomic)
        } catch {
            // The UI result remains authoritative; a CLI-only receipt failure
            // must not mutate the already verified task outcome.
        }
    }

    private func writeOrderRescueReplayScreenshot() {
        guard isReplayingOrderRescue, let replayScreenshotURL else { return }
        let hosting = NSHostingView(rootView: CompanionView(coordinator: self))
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        guard fittingSize.width >= 500, fittingSize.height >= 600 else { return }
        hosting.frame = NSRect(origin: .zero, size: fittingSize)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: replayScreenshotURL, options: .atomic)
    }

    private func isTaskActive(_ state: SessionState) -> Bool {
        switch state {
        case .listening, .grounding, .planning, .readyForCorrection,
             .correctionListening, .awaitingApproval, .acting, .verifying,
             .conversing:
            true
        case .idle, .result:
            false
        }
    }

    private func isVoiceCaptureState(_ state: SessionState) -> Bool {
        switch state {
        case .listening, .correctionListening: true
        default: false
        }
    }

    private func traceStage(for event: LedgerEventKind) -> TaskTraceStage {
        switch event {
        case .observed: .grounding
        case .interpreted, .decided: .planning
        case .acted: .action
        case .verified: .verification
        }
    }

    private func cleanupScreenContext() {
        guard let context = activeScreenContext else { return }
        activeScreenContext = nil
        Task {
            await screenContextCollector.cleanup(
                captureID: context.observation.captureID)
        }
    }

    private func sidecarEnvironment() -> [String: String] {
        var environment = (try? VLMCredentialStore().loadCommerceEnvironment()) ?? [:]
        let apiKey: String?
        do {
            apiKey = try VLMCredentialStore().load()
        } catch {
            return environment
        }
        guard let apiKey else {
            return environment
        }
        let model = UserDefaults.standard.string(
            forKey: VLMConfiguration.modelDefaultsKey)
            ?? VLMConfiguration.defaultModel
        environment["VOICEOPS_OPENAI_API_KEY"] = apiKey
        environment["VOICEOPS_VLM_MODEL"] = model
        environment["VOICEOPS_LLM_MODEL"] = model
        return environment
    }

    private func sidecarVLMEnvironment() -> [String: String] { sidecarEnvironment() }

    private func loadOpenAIApiKey() -> String? {
        try? VLMCredentialStore().load()
    }
}
