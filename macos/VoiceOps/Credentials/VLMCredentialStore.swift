import Foundation
@preconcurrency import Security

enum VLMConfiguration {
    static let keychainService = "com.voiceops.vlm"
    static let keychainAccount = "openai-api-key"
    static let modelDefaultsKey = "voiceops.vlm.openai.model"
    static let defaultModel = "gpt-5.6-sol"
}

enum VLMCredentialError: Error, LocalizedError {
    case invalidCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "Enter a non-empty OpenAI API key."
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
        var query = baseQuery
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
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VLMCredentialError.invalidCredential }
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw VLMCredentialError.keychain(updateStatus)
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VLMCredentialError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VLMCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VLMConfiguration.keychainService,
            kSecAttrAccount as String: VLMConfiguration.keychainAccount,
        ]
    }
}
