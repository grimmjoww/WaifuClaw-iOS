import Foundation
import Security

/// Device token + TLS pin storage. Keychain ONLY — never UserDefaults,
/// never logs, never plaintext files (G3).
enum KeychainStore {
    private static let service = "com.waifuclaw.remote"
    private static let tokenAccount = "deviceToken"
    private static let fingerprintAccount = "tlsFingerprint"
    private static let byokKeyAccount = "byokApiKey"

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
    /// as the device token. Wiped on unpair via `wipeAll()`.
    static var byokAPIKey: String? {
        get { read(account: byokKeyAccount) }
        set {
            if let newValue { write(newValue, account: byokKeyAccount) }
            else { delete(account: byokKeyAccount) }
        }
    }

    static func wipeAll() {
        delete(account: tokenAccount)
        delete(account: fingerprintAccount)
        delete(account: byokKeyAccount)
    }

    // MARK: - Private

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
