import Foundation
import Security

protocol NativeMCPCredentialStore: Sendable {
    func save(_ token: String, for serverID: UUID) throws
    func load(for serverID: UUID) throws -> String?
    func delete(for serverID: UUID) throws
}

struct NativeMCPKeychainCredentials: NativeMCPCredentialStore {
    private let service: String

    init(service: String = "studio.phantomhorizons.waifuclaw.mcp.bearer") {
        self.service = service
    }

    func save(_ token: String, for serverID: UUID) throws {
        let data = try Self.validated(token)
        let query = baseQuery(serverID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.status(added) }
        } else if status != errSecSuccess {
            throw CredentialError.status(status)
        }
    }

    func load(for serverID: UUID) throws -> String? {
        var query = baseQuery(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.status(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidEncoding
        }
        return token
    }

    func delete(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.status(status)
        }
    }

    static func validated(_ raw: String) throws -> Data {
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let data = raw.data(using: .utf8)
        else { throw NativeMCPError.invalidToken }
        return data
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    enum CredentialError: Error, LocalizedError {
        case status(OSStatus), invalidEncoding
        var errorDescription: String? { "Secure MCP credential storage is unavailable. Unlock the device and try again." }
    }
}
