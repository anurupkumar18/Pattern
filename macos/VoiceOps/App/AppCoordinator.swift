import AppKit
import Foundation
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

    private let narrator = Narrator()
    private var hotKey: HotKeyManager?
    private var panicStop: PanicStopMonitor?
    private var panel: CompanionPanelController?
    private var voiceSession: VoiceSessionController?
    private var sidecarClient: SidecarClient?
    private var sidecarTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private let screenContextCollector: any ScreenContextCollecting = NativeScreenContextCollector()
    private let reminderWorkflow = EventKitReminderWorkflow()
    private let meetingBriefingWorkflow = EventKitMeetingBriefingWorkflow()
    private let researchFollowupWorkflow = ResearchFollowupWorkflow()
    private var activeScreenContext: CollectedScreenContext?
    private var attemptLedger = ActionAttemptLedger()
    private var cachedActions: [String: ActionResult] = [:]
    private var activeTaskID: UUID?
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
        panicStop = PanicStopMonitor { [weak self] in self?.stop() }
        panel = CompanionPanelController(coordinator: self)
    }

    func toggle() { dispatch(.hotkeyTapped) }
    func stop() {
        resolveApproval(false)
        dispatch(.stopRequested)
    }
    func approvePendingAction() {
        guard case .awaitingApproval = state else { return }
        let continuation = approvalContinuation
        approvalContinuation = nil
        dispatch(.approvalGranted)
        continuation?.resume(returning: true)
    }
    func denyPendingAction() {
        guard case .awaitingApproval = state else { return }
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: false)
        dispatch(.approvalDenied)
    }
    func dismiss() { dispatch(.dismissResult) }
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
            cleanupScreenContext()
            panel?.hide()

        case .listening:
            // Partial transcript events stay in `.listening`. Only the initial
            // idle -> listening transition may reset the session and install
            // an audio tap; otherwise every partial would start another
            // VoiceSessionController on the same AVAudioEngine input.
            guard case .idle = previous else { return }
            taskTrace = TaskTrace()
            recordTrace(.listening, "Voice capture started")
            permissionSettingsURL = nil
            groundingChips = []
            groundingAdapter = nil
            groundingWarnings = []
            verificationResults = []
            cleanupScreenContext()
            panel?.show()
            narrator.say("Listening")
            startCapture()

        case .grounding:
            recordTrace(.grounding, "Collecting task-scoped screen context")
            if case .listening = previous {
                narrator.say("Got it")
                finishCaptureAndCollectContext()
            }

        case .planning:
            recordTrace(.planning, "Grounded context sent to the typed planner")
            narrator.say("I found the visible context")

        case .awaitingApproval:
            recordTrace(.approval, "Waiting for explicit schedule approval")
            narrator.say("Approval needed")

        case .acting:
            recordTrace(.action, "Approved plan entered native execution")
            narrator.say("Working on it")

        case .verifying:
            recordTrace(.verification, "Independent fetch-back verification started")
            narrator.say("Verifying")

        case .result(let result):
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
                case .succeeded: narrator.say("Done")
                case .partial: narrator.say("Partially completed")
                case .failed: narrator.say("Verification failed")
                case .needsUser: narrator.say("I need one detail")
                }
            case .failed: narrator.say("That didn't work")
            case .cancelled: narrator.say("Stopped")
            }
            cancelCapture()
            contextTask?.cancel()
            contextTask = nil
            cancelSidecar()
            cleanupScreenContext()
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
            controller.onError = { [weak self] in
                self?.dispatch(.taskFailed(reason: "Speech capture failed: \($0.localizedDescription)"))
            }
            voiceSession = controller
            do {
                try await controller.begin()
            } catch {
                dispatch(.taskFailed(reason: "Could not start audio capture: \(error.localizedDescription)"))
            }
        }
    }

    private func finishCaptureAndCollectContext() {
        contextTask = Task { [weak self] in
            guard let self, let voiceSession else { return }
            do {
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
                        let chips = grounding.references.compactMap {
                            GroundingChip(
                                reference: $0,
                                candidates: context.observation.elements)
                        }
                        self?.groundingChips = chips
                        self?.groundingAdapter = grounding.adapter
                        self?.groundingWarnings = grounding.warnings
                        self?.dispatch(.groundingReady(chips))
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

    private func isTaskActive(_ state: SessionState) -> Bool {
        switch state {
        case .listening, .grounding, .planning, .awaitingApproval, .acting, .verifying:
            true
        case .idle, .result:
            false
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

    private func sidecarVLMEnvironment() -> [String: String] {
        let apiKey: String?
        do {
            apiKey = try VLMCredentialStore().load()
        } catch {
            return [:]
        }
        guard let apiKey else {
            return [:]
        }
        let model = UserDefaults.standard.string(
            forKey: VLMConfiguration.modelDefaultsKey)
            ?? VLMConfiguration.defaultModel
        return [
            "VOICEOPS_OPENAI_API_KEY": apiKey,
            "VOICEOPS_VLM_MODEL": model,
        ]
    }
}
