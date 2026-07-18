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
    @Published var conversationalVoice: Bool
    @Published var shopifyShop = ""
    @Published var shopifyToken = ""
    @Published var shopifyOrderID = ""
    @Published var slackBotToken = ""
    @Published var slackChannelID = ""
    @Published private(set) var isConfigured = false
    @Published private(set) var commerceConfigured = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var demoPermissions: [DemoPermissionReadiness] = []

    private let store = VLMCredentialStore()

    init() {
        model = UserDefaults.standard.string(
            forKey: VLMConfiguration.modelDefaultsKey)
            ?? VLMConfiguration.defaultModel
        conversationalVoice = UserDefaults.standard.object(
            forKey: VLMConfiguration.conversationalVoiceDefaultsKey) as? Bool ?? true
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
            UserDefaults.standard.set(
                conversationalVoice,
                forKey: VLMConfiguration.conversationalVoiceDefaultsKey)
            isConfigured = true
            statusIsError = false
            statusMessage = "Saved securely. OpenAI Realtime voice and flagship vision are enabled."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            refreshConfigurationFlag()
        }
    }

    func saveCommerce() {
        do {
            let pending: [(CommerceCredential, String)] = [
                (.shopifyShop, shopifyShop), (.shopifyToken, shopifyToken),
                (.shopifyOrderID, shopifyOrderID), (.slackBotToken, slackBotToken),
                (.slackChannelID, slackChannelID),
            ]
            for (credential, value) in pending
                where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.save(value, for: credential)
            }
            clearPendingCommerce()
            refreshCommerceFlag()
            guard commerceConfigured else {
                throw VLMCredentialError.incompleteCommerceCredentials
            }
            statusIsError = false
            statusMessage = "Commerce sandbox credentials saved. Shopify and Slack health are probed by the sidecar before live selection."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            refreshCommerceFlag()
        }
    }

    func removeCommerceCredentials() {
        do {
            for credential in CommerceCredential.allCases { try store.delete(credential) }
            clearPendingCommerce()
            commerceConfigured = false
            statusIsError = false
            statusMessage = "Commerce credentials removed. Order Rescue will use the visibly labeled fixture channel."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
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
        refreshCommerceFlag()
    }

    private func refreshCommerceFlag() {
        do {
            commerceConfigured = try store.loadCommerceEnvironment().count
                == CommerceCredential.allCases.count
        } catch {
            commerceConfigured = false
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func clearPendingCommerce() {
        shopifyShop = ""
        shopifyToken = ""
        shopifyOrderID = ""
        slackBotToken = ""
        slackChannelID = ""
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
                Toggle("Conversational voice (Realtime S2S)", isOn: $model.conversationalVoice)
                Text("Default: \(VLMConfiguration.defaultModel). The model name is not secret and is stored in UserDefaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commerce Sandbox") {
                LabeledContent("Selection") {
                    Label(
                        model.commerceConfigured
                            ? "Credentials ready · health probe at session start"
                            : "Fixture fallback armed",
                        systemImage: model.commerceConfigured
                            ? "checkmark.circle.fill" : "shippingbox")
                }
                TextField("Shopify shop (store.myshopify.com)", text: $model.shopifyShop)
                SecureField("Shopify Admin access token", text: $model.shopifyToken)
                TextField("Shopify test order ID", text: $model.shopifyOrderID)
                SecureField("Slack bot token", text: $model.slackBotToken)
                TextField("Slack shipping-escalations channel ID", text: $model.slackChannelID)
                Text("Live mode is selected only when all five values exist and both Shopify and Slack health probes pass. Any failure remains on the deterministic fixture channel and is labeled in the ledger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if model.commerceConfigured {
                        Button("Remove Commerce Credentials", role: .destructive) {
                            model.removeCommerceCredentials()
                        }
                    }
                    Spacer()
                    Button("Save Commerce Sandbox") { model.saveCommerce() }
                }
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
        .frame(width: 660, height: 820)
        .onAppear { model.refreshDemoReadiness() }
    }
}
