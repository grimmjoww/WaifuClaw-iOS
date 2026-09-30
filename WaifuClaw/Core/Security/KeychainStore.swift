import Foundation
import Security

/// Device token + TLS pin storage. Keychain ONLY — never UserDefaults,
/// never logs, never plaintext files (G3).
enum KeychainStore {
    private static let service = "com.waifuclaw.remote"
    private static let tokenAccount = "deviceToken"
    private static let fingerprintAccount = "tlsFingerprint"
    private static let byokKeyAccount = "byokApiKey"

    enum StorageError: LocalizedError {
        case status(OSStatus)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .status(let code): "Secure storage is unavailable (\(code)). Unlock your phone and try again."
            case .invalidEncoding: "The saved key couldn't be read."
            }
        }
    }

    // MARK: Device token

    static var deviceToken: String? {
        get { read(account: tokenAccount) }
        set {
            if let newValue { write(newValue, account: tokenAccount) }
            else { delete(account: tokenAccount) }
        }
    }

    // MARK: Pinned TLS fingerprint (TOFU anchor from the pairing QR)

    static var pinnedFingerprint: String? {
        get { read(account: fingerprintAccount) }
        set {
            if let newValue { write(newValue, account: fingerprintAccount) }
            else { delete(account: fingerprintAccount) }
        }
    }

    // MARK: BYOK provider key (free tier)

    /// The user's own LLM provider key. Keychain only — same accessibility
    /// as the device token. Legacy desktop unpairing must not erase it.
    static var byokAPIKey: String? {
        get { read(account: byokKeyAccount) }
        set {
            if let newValue { write(newValue, account: byokKeyAccount) }
            else { delete(account: byokKeyAccount) }
        }
    }

    static func wipePairingCredentials() {
        delete(account: tokenAccount)
        delete(account: fingerprintAccount)
    }

    /// Only an explicit full credential reset should also remove BYOK.
    static func wipeAll() {
        wipePairingCredentials()
        delete(account: byokKeyAccount)
    }

    /// The native agent shares the existing BYOK account so a previous key is
    /// not silently lost on upgrade. The selected provider/model is separate.
    static func saveAgentKey(_ value: String) throws {
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            throw StorageError.invalidEncoding
        }
        let query = baseQuery(account: byokKeyAccount)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StorageError.status(addStatus) }
        } else if status != errSecSuccess {
            throw StorageError.status(status)
        }
    }

    static func agentKey() throws -> String? {
        var query = baseQuery(account: byokKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidEncoding
        }
        return value
    }

    static func deleteAgentKey() throws {
        let status = SecItemDelete(baseQuery(account: byokKeyAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.status(status)
        }
    }

    // MARK: - Private

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessibility: only unlockable when the device is unlocked.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
