import Foundation
@preconcurrency import Security

enum VLMConfiguration {
    static let keychainService = "com.voiceops.vlm"
    static let keychainAccount = "openai-api-key"
    static let modelDefaultsKey = "voiceops.vlm.openai.model"
    static let defaultModel = "gpt-5.6-sol"
    static let conversationalVoiceDefaultsKey = "voiceops.voice.conversational.enabled"
}

enum CommerceCredential: String, CaseIterable, Sendable {
    case shopifyShop = "VOICEOPS_SHOPIFY_SHOP"
    case shopifyToken = "VOICEOPS_SHOPIFY_TOKEN"
    case shopifyOrderID = "VOICEOPS_SHOPIFY_ORDER_ID"
    case slackBotToken = "VOICEOPS_SLACK_BOT_TOKEN"
    case slackChannelID = "VOICEOPS_SLACK_CHANNEL_ID"

    var account: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "-") }
}

enum VLMCredentialError: Error, LocalizedError {
    case invalidCredential
    case incompleteCommerceCredentials
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "Enter a non-empty OpenAI API key."
        case .incompleteCommerceCredentials:
            "Enter all five Shopify and Slack sandbox values."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}

/// Stores the provider secret in the user's login Keychain. The value is read
/// only when spawning a task sidecar and is never written to UserDefaults,
/// source files, logs, or the app bundle.
struct VLMCredentialStore: Sendable {
    func load() throws -> String? {
        try load(account: VLMConfiguration.keychainAccount)
    }

    func load(_ credential: CommerceCredential) throws -> String? {
        try load(account: credential.account)
    }

    func loadCommerceEnvironment() throws -> [String: String] {
        var environment: [String: String] = [:]
        for credential in CommerceCredential.allCases {
            if let value = try load(credential) {
                environment[credential.rawValue] = value
            }
        }
        return environment
    }

    private func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VLMCredentialError.keychain(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { throw VLMCredentialError.invalidCredential }
        return value
    }

    func save(_ credential: String) throws {
        try save(credential, account: VLMConfiguration.keychainAccount)
    }

    func save(_ value: String, for credential: CommerceCredential) throws {
        try save(value, account: credential.account)
    }

    private func save(_ credential: String, account: String) throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VLMCredentialError.invalidCredential }
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw VLMCredentialError.keychain(updateStatus)
        }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VLMCredentialError.keychain(addStatus)
        }
    }

    func delete() throws {
        try delete(account: VLMConfiguration.keychainAccount)
    }

    func delete(_ credential: CommerceCredential) throws {
        try delete(account: credential.account)
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VLMCredentialError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VLMConfiguration.keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
