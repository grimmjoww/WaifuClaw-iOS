import Foundation
import Security

/// Dedicated storage for the TypeSafe Jev credential. This deliberately uses a
/// different Keychain service and account from the coding-model BYOK key.
struct JevKeychainStore: Sendable {
    private let service: String
    private let account: String

    init() {
        service = "studio.phantomhorizons.waifuclaw.jev"
        account = "typesafeApiKey"
    }

    /// Internal dependency injection for isolated Keychain tests only.
    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    enum StorageError: LocalizedError, Equatable, Sendable {
        case invalidKey
        case status(OSStatus)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                "Enter a valid Jev API key before saving."
            case .status(let status):
                "Secure Jev key storage is unavailable (\(status)). Unlock your phone and try again."
            case .invalidEncoding:
                "The saved Jev key could not be read."
            }
        }
    }

    func save(_ apiKey: String) throws {
        let value = try validatedKey(apiKey)
        guard let data = value.data(using: .utf8) else {
            throw StorageError.invalidEncoding
        }

        let query = baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StorageError.status(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw StorageError.status(updateStatus)
        }
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StorageError.status(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw StorageError.invalidEncoding
        }
        return value
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.status(status)
        }
    }

    private func validatedKey(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 4_096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw StorageError.invalidKey
        }
        return value
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
