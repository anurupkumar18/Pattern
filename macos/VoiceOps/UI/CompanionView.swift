import SwiftUI
import VoiceOpsCore

/// One view, one source of truth: renders exactly the SessionState the
/// coordinator publishes. Status is conveyed by symbol + text, never color
/// alone (PRD accessibility requirement).
struct CompanionView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var timelineExpanded = false
    @State private var planExpanded = true
    @State private var ledgerExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if coordinator.state != .idle { voiceMethod }
            if showsDetailedWork {
                ScrollView {
                    detailContent
                }
                .frame(height: 560)
            } else {
                detailContent
            }
            footer
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.15), value: coordinator.state)
    }

    private var showsDetailedWork: Bool {
        coordinator.activeTaskSpec != nil || !coordinator.executionLedger.isEmpty
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let approval = coordinator.pendingConversationApproval {
                conversationApprovalCard(approval)
            }
            if coordinator.activeTaskSpec != nil { versionedPlan }
            if !coordinator.executionLedger.isEmpty { executionLedger }
            if coordinator.state != .idle { taskTimeline }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voiceMethod: some View {
        HStack(spacing: 6) {
            Image(systemName: coordinator.voiceFallbackActive
                ? "arrow.triangle.2.circlepath" : "waveform.badge.mic")
            Text(coordinator.voiceProvider).font(.caption.weight(.semibold))
            Text(coordinator.voiceModel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(coordinator.voiceStatus)
                .font(.caption2.monospaced().weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Voice provider \(coordinator.voiceProvider), model \(coordinator.voiceModel), "
                + "status \(coordinator.voiceStatus)")
    }

    private var taskTimeline: some View {
        DisclosureGroup(isExpanded: $timelineExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(coordinator.taskTrace.entries.suffix(8))) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.1fs", Double(entry.elapsedMilliseconds) / 1_000))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption2)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Label("Task timeline", systemImage: "clock.arrow.circlepath")
                Spacer()
                if coordinator.taskTrace.recoveryCount > 0 {
                    Text("\(coordinator.taskTrace.recoveryCount) recovery")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .onChange(of: coordinator.taskTrace.recoveryCount) { _, count in
            if count > 0 { timelineExpanded = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.large)
            Text(statusTitle)
                .font(.headline)
            Spacer()
            Text("⌃⌥V")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("VoiceOps status: \(statusTitle)")
    }

    private var statusSymbol: String {
        switch coordinator.state {
        case .idle: "waveform.circle"
        case .listening: "mic.fill"
        case .grounding: "viewfinder.circle"
        case .planning: "brain"
        case .readyForCorrection: "square.and.pencil"
        case .correctionListening: "waveform.badge.mic"
        case .awaitingApproval: "hand.raised.fill"
        case .acting: "gearshape.2.fill"
        case .verifying: "checklist"
        case .conversing(let speaking, _, _):
            speaking ? "waveform.and.person.filled" : "person.wave.2.fill"
        case .result(.completed(let state, _)):
            switch state {
            case .succeeded: "checkmark.seal.fill"
            case .partial: "exclamationmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .needsUser: "questionmark.circle.fill"
            }
        case .result(.failed): "exclamationmark.triangle.fill"
        case .result(.cancelled): "stop.circle.fill"
        }
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle: "Idle"
        case .listening: "Listening…"
        case .grounding: "Grounding"
        case .planning: "Planning"
        case .readyForCorrection(_, let version, _): "Plan v\(version) ready"
        case .correctionListening: "Listening for correction…"
        case .awaitingApproval: "Approval needed"
        case .acting: "Acting"
        case .verifying: "Verifying"
        case .conversing(let speaking, let version, _):
            if let version {
                "In conversation — plan v\(version)"
            } else {
                speaking ? "VoiceOps speaking…" : "In conversation"
            }
        case .result(.completed(let state, _)): state == .succeeded ? "Done" : "Finished: \(state.rawValue)"
        case .result(.failed): "Failed"
        case .result(.cancelled): "Stopped"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            Text("Press ⌃⌥V and speak a goal.")
                .foregroundStyle(.secondary)

        case .listening(let transcript):
            transcriptView(transcript.isEmpty ? "…" : transcript)

        case .conversing(let speaking, let version, let transcript):
            VStack(alignment: .leading, spacing: 8) {
                transcriptView(transcript.isEmpty ? "…" : transcript)
                if !coordinator.agentTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VOICEOPS").font(.caption2.monospaced().weight(.bold))
                        Text(coordinator.agentTranscript)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 6) {
                    Image(systemName: speaking ? "speaker.wave.2.fill" : "mic.fill")
                        .foregroundStyle(speaking ? Color.accentColor : .secondary)
                    Text(speaking
                        ? "VoiceOps is speaking — talk to interrupt"
                        : "Listening")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let version {
                        Spacer()
                        Text("v\(version)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }

        case .grounding(let transcript):
            VStack(alignment: .leading, spacing: 6) {
                transcriptView(transcript)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the active window")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .planning(let transcript, let chips):
            VStack(alignment: .leading, spacing: 8) {
                transcriptView(transcript)
                groundingChips(chips)
                groundingMethod
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Interpreting your request")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .readyForCorrection(let objective, let version, let chips):
            VStack(alignment: .leading, spacing: 8) {
                groundingChips(chips)
                groundingMethod
                Label("Persistent task compiled · version \(version)", systemImage: "checkmark.seal")
                    .font(.callout.weight(.semibold))
                Text(objective).font(.callout)
                Text("Press ⌃⌥V and speak a correction. VoiceOps will patch this task instead of restarting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .correctionListening(let transcript, let version, _):
            VStack(alignment: .leading, spacing: 8) {
                Label("Patching task version \(version)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                transcriptView(transcript.isEmpty ? "…" : transcript)
                Text("Press ⌃⌥V again to apply the correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .awaitingApproval(let description, let chips):
            VStack(alignment: .leading, spacing: 8) {
                groundingChips(chips)
                groundingMethod
                Label("Review before VoiceOps writes to Notes and Reminders", systemImage: "calendar.badge.clock")
                    .font(.callout.weight(.semibold))
                Text(description)
                    .font(.callout)
                Text("Nothing will be created until you approve these dates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .acting(let description, let chips):
            VStack(alignment: .leading, spacing: 8) {
                groundingChips(chips)
                groundingMethod
                Text(description).font(.callout)
            }

        case .verifying:
            Text("Checking that the result really exists…")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .result(let result):
            resultView(result)
        }
    }

    private var versionedPlan: some View {
        DisclosureGroup(isExpanded: $planExpanded) {
            if let task = coordinator.activeTaskSpec {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Text("Raw request").font(.caption2.weight(.semibold))
                        Text(task.rawRequest).font(.caption).foregroundStyle(.secondary)
                        Text("Objective").font(.caption2.weight(.semibold))
                        Text(task.objective).font(.caption)
                    }
                    Text("Grounded entities").font(.caption2.weight(.semibold))
                    ForEach(task.entities.keys.sorted(), id: \.self) { key in
                        if let value = task.entities[key] {
                            Text("\(humanize(key)): \(value)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text("Evidence to collect").font(.caption2.weight(.semibold))
                    ForEach(task.evidenceToCollect, id: \.self) { evidence in
                        Label(evidence, systemImage: "magnifyingglass")
                            .font(.caption)
                    }
                    Divider()
                    Text("Actions").font(.caption2.weight(.semibold))
                    ForEach(task.actions.keys.sorted(), id: \.self) { actionID in
                        if let action = task.actions[actionID] {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: action.status == .cancelled
                                    ? "minus.circle" : "circle")
                                Text(action.description).font(.caption)
                                Spacer(minLength: 4)
                                Text(action.risk.rawValue.replacingOccurrences(
                                    of: "_", with: " "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Constraints").font(.caption2.weight(.semibold))
                    ForEach(task.constraints.keys.sorted(), id: \.self) { key in
                        if let value = task.constraints[key] {
                            Label(value, systemImage: "lock.shield")
                                .font(.caption)
                        }
                    }
                    Text("Completion criteria").font(.caption2.weight(.semibold))
                    ForEach(task.completionCriteria.keys.sorted(), id: \.self) { key in
                        if let value = task.completionCriteria[key] {
                            Label(value, systemImage: "checkmark.circle")
                                .font(.caption)
                        }
                    }
                    if let patch = coordinator.appliedPlanPatch {
                        Divider()
                        Label(
                            "Patch v\(patch.baseVersion) → v\(patch.newVersion)",
                            systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                        Text("Voice correction")
                            .font(.caption2.weight(.semibold))
                        Text(patch.transcript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(patch.operations.enumerated()), id: \.offset) { _, operation in
                            Label(
                                "\(operation.operation.rawValue.capitalized) · "
                                    + humanizePatchTarget(operation.target),
                                systemImage: patchOperationSymbol(operation.operation))
                                .font(.caption)
                        }
                        Text("Preserved · \(patch.preserved.count) task fields")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            HStack {
                Label("Versioned action plan", systemImage: "list.bullet.clipboard")
                Spacer()
                if let task = coordinator.activeTaskSpec {
                    Text("v\(task.version)")
                        .font(.caption2.monospaced().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
        }
    }

    private var executionLedger: some View {
        DisclosureGroup(isExpanded: $ledgerExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(coordinator.executionLedger, id: \.sequence) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(event.eventType.rawValue.uppercased())
                                .font(.caption2.monospaced().weight(.bold))
                            Text(event.timestamp, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.whereText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(event.what).font(.caption)
                        if let found = event.found {
                            Text(found).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Why it matters: \(event.whyItMatters)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Source: \(event.source) · Confidence: \(Int(event.confidence * 100))%")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let next = event.next {
                            Text("Next: \(next)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Execution ledger", systemImage: "point.3.connected.trianglepath.dotted")
                Spacer()
                Text("\(coordinator.executionLedger.count) events")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func transcriptView(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Transcript: \(text)")
    }

    @ViewBuilder
    private func resultView(_ result: SessionResult) -> some View {
        switch result {
        case .completed(_, let summary):
            VStack(alignment: .leading, spacing: 8) {
                groundingChips(coordinator.groundingChips)
                groundingMethod
                Text(summary).font(.callout)
                verificationChecklist
                if coordinator.permissionSettingsURL != nil {
                    Button("Open Privacy Settings") {
                        coordinator.openPermissionSettings()
                    }
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(reason).font(.callout)
                if coordinator.permissionSettingsURL != nil {
                    Button("Open Privacy Settings") {
                        coordinator.openPermissionSettings()
                    }
                }
            }
        case .cancelled:
            Text("Cancelled. Nothing else will run.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var verificationChecklist: some View {
        if !coordinator.verificationResults.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verification evidence")
                    .font(.caption.weight(.semibold))
                ForEach(coordinator.verificationResults, id: \.predicateId) { result in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: result.passed
                            ? "checkmark.circle.fill" : "xmark.circle.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verificationLabel(result.predicateId))
                                .font(.caption)
                            if let reason = result.failureReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(verificationLabel(result.predicateId)): "
                        + (result.passed ? "passed" : "failed"))
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func verificationLabel(_ predicateID: String) -> String {
        switch predicateID {
        case "reminder-exists": "Reminder fetched back"
        case "reminder-title": "Title matches commitment"
        case "reminder-due-date": "Due date matches"
        case "reminder-notes": "Source notes retained"
        case "reminder-visible": "Visible in Reminders"
        case "meeting-selected": "Next meeting confirmed"
        case "brief-exists": "Briefing note fetched back"
        case "brief-headings": "Required sections present"
        case "brief-meeting-identity": "Meeting title and time match"
        case "brief-visible": "Visible in Notes"
        case "research-note-exists": "Comparison note fetched back"
        case "research-exactly-three": "Exactly three recommendations"
        case "research-citations": "Sources and rationale retained"
        case "research-followups": "Three approved follow-ups match"
        case "research-visible": "Research note visible in Notes"
        case "tracking-reviewed": "Tracking reviewed"
        case "shopify-updated": "Shopify updated and $20 credit issued"
        case "customer-contacted": "Customer choice message in Sent"
        case "operations-notified": "Sarah notified in Slack"
        case "followup-scheduled": "Follow-up scheduled"
        case "no-refund-issued": "Confirmed: no refund issued"
        case "no-replacement-created": "Confirmed: no replacement created"
        default: predicateID.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func humanizePatchTarget(_ target: String) -> String {
        target
            .split(separator: ".")
            .map { humanize(String($0)) }
            .joined(separator: " → ")
    }

    private func patchOperationSymbol(_ operation: PatchOperationKind) -> String {
        switch operation {
        case .add: "plus.circle"
        case .remove: "minus.circle"
        case .replace: "arrow.triangle.2.circlepath"
        }
    }

    @ViewBuilder
    private var groundingMethod: some View {
        if let adapter = coordinator.groundingAdapter {
            Label(
                adapter == .openai ? "OpenAI vision grounding" : "Deterministic grounding",
                systemImage: adapter == .openai ? "eye.fill" : "text.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        ForEach(Array(coordinator.groundingWarnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func groundingChips(_ chips: [GroundingChip]) -> some View {
        if chips.isEmpty {
            Text("No explicit screen reference found")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 5) {
                    Image(systemName: "scope")
                    Text("\(chip.phrase) → \(chip.resolvedText)")
                        .lineLimit(2)
                    Text(chip.source.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .accessibilityLabel(
                    "Grounded \(chip.phrase) to \(chip.resolvedText) from \(chip.source.rawValue)")
            }
        }
    }

    // MARK: Footer

    private func conversationApprovalCard(
        _ approval: ConversationApprovalCard
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Bound approval read-back", systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
            Text(approval.readBack).font(.callout.weight(.medium))
            Text("Binding \(approval.bindingHash.prefix(12))… · \(approval.actionIDs.count) actions")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("Say an unambiguous yes, or use the button below. Both authorize only this exact hash.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var footer: some View {
        if coordinator.pendingConversationApproval != nil {
            HStack {
                Button("Cancel") { coordinator.denyPendingAction() }
                Spacer()
                Button("Approve exact actions") { coordinator.approvePendingAction() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch coordinator.state {
            case .awaitingApproval:
                HStack {
                    Button("Cancel") { coordinator.denyPendingAction() }
                    Spacer()
                    Button("Approve Schedule") { coordinator.approvePendingAction() }
                        .buttonStyle(.borderedProminent)
                }
            case .listening, .grounding, .planning, .readyForCorrection,
                 .correctionListening, .acting, .verifying, .conversing:
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        coordinator.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.cancelAction)
                }
            case .result:
                HStack {
                    Spacer()
                    Button("Dismiss") { coordinator.dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            case .idle:
                EmptyView()
            }
        }
    }
}
