import SwiftUI
import VoiceOpsCore

/// One view, one source of truth: renders exactly the SessionState the
/// coordinator publishes. Status is conveyed by symbol + text, never color
/// alone (PRD accessibility requirement).
struct CompanionView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.15), value: coordinator.state)
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
        case .acting: "gearshape.2.fill"
        case .verifying: "checklist"
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
        case .acting: "Acting"
        case .verifying: "Verifying"
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
        default: predicateID.replacingOccurrences(of: "-", with: " ").capitalized
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

    @ViewBuilder
    private var footer: some View {
        switch coordinator.state {
        case .listening, .grounding, .planning, .acting, .verifying:
            HStack {
                Spacer()
                Button(role: .destructive) {
                    coordinator.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.cancelAction)  // Escape while the panel has focus
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
