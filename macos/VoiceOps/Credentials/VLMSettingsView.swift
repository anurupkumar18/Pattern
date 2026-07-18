import SwiftUI

@MainActor
final class VLMSettingsModel: ObservableObject {
    @Published var pendingAPIKey = ""
    @Published var model: String
    @Published private(set) var isConfigured = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let store = VLMCredentialStore()

    init() {
        model = UserDefaults.standard.string(
            forKey: VLMConfiguration.modelDefaultsKey)
            ?? VLMConfiguration.defaultModel
        refresh()
    }

    func save() {
        do {
            if !pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.save(pendingAPIKey)
                pendingAPIKey = ""
            } else if try store.load() == nil {
                throw VLMCredentialError.invalidCredential
            }
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            model = normalizedModel.isEmpty ? VLMConfiguration.defaultModel : normalizedModel
            UserDefaults.standard.set(model, forKey: VLMConfiguration.modelDefaultsKey)
            isConfigured = true
            statusIsError = false
            statusMessage = "Saved securely. OpenAI Realtime voice and flagship vision are enabled."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            refreshConfigurationFlag()
        }
    }

    func removeCredential() {
        do {
            try store.delete()
            pendingAPIKey = ""
            isConfigured = false
            statusIsError = false
            statusMessage = "Credential removed. VoiceOps will use Apple Speech and deterministic grounding."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func refresh() {
        statusMessage = nil
        statusIsError = false
        refreshConfigurationFlag()
    }

    private func refreshConfigurationFlag() {
        do {
            isConfigured = try store.load() != nil
        } catch {
            isConfigured = false
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

struct VLMSettingsView: View {
    @StateObject private var model = VLMSettingsModel()

    var body: some View {
        Form {
            Section("OpenAI voice and intelligence") {
                LabeledContent("Voice", value: "gpt-realtime-whisper · Apple Speech failover")
                LabeledContent("Vision", value: "OpenAI Responses API")
                LabeledContent("Status") {
                    Label(
                        model.isConfigured ? "Realtime + flagship enabled" : "Local fallbacks active",
                        systemImage: model.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle")
                }
                SecureField(
                    model.isConfigured
                        ? "Paste a new key to replace the stored credential"
                        : "OpenAI API key",
                    text: $model.pendingAPIKey)
                    .textContentType(.password)
                TextField("Vision model", text: $model.model)
                Text("Default: \(VLMConfiguration.defaultModel). The model name is not secret and is stored in UserDefaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("The API key is stored in your macOS login Keychain. It is used only by the live Realtime voice socket and per-task local sidecar; it is never saved in the repository, app bundle, screenshots, or logs.")
                    .font(.callout)
                Text("When configured, microphone PCM is streamed only during an active hotkey capture. The active-window screenshot and pruned accessibility candidates are sent only during task grounding. Captures remain task-scoped and are deleted at the terminal state.")
                    .font(.callout)
            }

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .foregroundStyle(model.statusIsError ? .red : .secondary)
            }

            HStack {
                Link("Create or manage an API key", destination: URL(
                    string: "https://platform.openai.com/api-keys")!)
                Spacer()
                if model.isConfigured {
                    Button("Remove Key", role: .destructive) {
                        model.removeCredential()
                    }
                }
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 430)
    }
}
