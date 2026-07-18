import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import Speech
import SwiftUI

struct DemoPermissionReadiness: Identifiable {
    let id: String
    let label: String
    let detail: String
    let isReady: Bool
}

@MainActor
final class VLMSettingsModel: ObservableObject {
    @Published var pendingAPIKey = ""
    @Published var model: String
    @Published private(set) var isConfigured = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var demoPermissions: [DemoPermissionReadiness] = []

    private let store = VLMCredentialStore()

    init() {
        model = UserDefaults.standard.string(
            forKey: VLMConfiguration.modelDefaultsKey)
            ?? VLMConfiguration.defaultModel
        refresh()
        refreshDemoReadiness()
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

    func refreshDemoReadiness() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let screenCaptureReady = CGPreflightScreenCaptureAccess()
        let accessibilityReady = AXIsProcessTrusted()
        demoPermissions = [
            DemoPermissionReadiness(
                id: "microphone", label: "Microphone",
                detail: Self.captureAuthorizationLabel(microphone),
                isReady: microphone == .authorized),
            DemoPermissionReadiness(
                id: "speech", label: "Apple Speech fallback",
                detail: Self.speechAuthorizationLabel(speech),
                isReady: speech == .authorized),
            DemoPermissionReadiness(
                id: "screen", label: "Screen Recording",
                detail: screenCaptureReady ? "Ready" : "Enable in System Settings",
                isReady: screenCaptureReady),
            DemoPermissionReadiness(
                id: "accessibility", label: "Accessibility / global stop",
                detail: accessibilityReady ? "Ready" : "Enable in System Settings",
                isReady: accessibilityReady),
        ]
    }

    func openPrivacySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy")
        else { return }
        NSWorkspace.shared.open(url)
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

    private static func captureAuthorizationLabel(
        _ status: AVAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized: "Ready"
        case .notDetermined: "Ask on first use"
        case .denied, .restricted: "Enable in System Settings"
        @unknown default: "Check System Settings"
        }
    }

    private static func speechAuthorizationLabel(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized: "Ready"
        case .notDetermined: "Ask on first use"
        case .denied, .restricted: "Enable in System Settings"
        @unknown default: "Check System Settings"
        }
    }
}

struct VLMSettingsView: View {
    @StateObject private var model = VLMSettingsModel()

    var body: some View {
        Form {
            Section("OpenAI voice and intelligence") {
                LabeledContent(
                    "Voice",
                    value: "Realtime Whisper → 4o Transcribe · Apple Speech failover"
                )
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
                Text("The API key is stored in your macOS login Keychain. It is used only by the live Realtime voice socket, final transcription request, and per-task local sidecar; it is never saved in the repository, app bundle, screenshots, or logs.")
                    .font(.callout)
                Text("When configured, microphone PCM is streamed during active hotkey capture. On commit, up to 10 MiB of task-scoped, in-memory PCM may be sent once to the final transcription model, then released after finalization or cancellation. The active-window screenshot and pruned accessibility candidates are sent only during task grounding. Captures are deleted at the terminal state.")
                    .font(.callout)
            }

            Section("Live demo readiness") {
                ForEach(model.demoPermissions) { permission in
                    LabeledContent(permission.label) {
                        Label(
                            permission.detail,
                            systemImage: permission.isReady
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(permission.isReady ? .green : .orange)
                    }
                }
                Text("OpenAI Realtime needs Microphone access. The zero-credential Apple fallback also needs Speech Recognition. Screen Recording grounds the active window; Accessibility enables the global Escape stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Refresh Readiness") { model.refreshDemoReadiness() }
                    Spacer()
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                }
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
        .frame(width: 620, height: 650)
        .onAppear { model.refreshDemoReadiness() }
    }
}
