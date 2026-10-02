import CryptoKit
import Foundation

/// Registry and audit live only in Application Support; the bearer token lives ONLY
/// in Keychain. File writes are atomic and errors are propagated (never silently lost).
actor NativeMCPRegistry {
    private let configURL: URL
    private let auditURL: URL
    private let credentials: any NativeMCPCredentialStore
    private var servers: [NativeMCPServer]
    private var events: [NativeMCPAuditEvent]

    init(directoryURL: URL? = nil,
         credentials: any NativeMCPCredentialStore = NativeMCPKeychainCredentials()) throws {
        let directory = try directoryURL ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("NativeMCP", isDirectory: true)
        guard directory.isFileURL else { throw NativeMCPError.invalidURL }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("servers.json")
        auditURL = directory.appendingPathComponent("audit.json")
        self.credentials = credentials
        servers = try Self.read([NativeMCPServer].self, from: configURL) ?? []
        events = try Self.read([NativeMCPAuditEvent].self, from: auditURL) ?? []
        guard servers.count <= 24, events.count <= 500 else { throw NativeMCPError.invalidResponse }
        // Never trust an on-disk URL after an upgrade or external file modification.
        for server in servers { _ = try NativeMCPEndpoint.validate(server.endpoint) }
    }

    func allServers() -> [NativeMCPServer] { servers }
    func server(_ id: UUID) throws -> NativeMCPServer {
        guard let found = servers.first(where: { $0.id == id }) else { throw NativeMCPError.missingServer }
        return found
    }

    @discardableResult
    func addServer(name: String, endpoint: String, bearerToken: String? = nil) throws -> NativeMCPServer {
        let url = try NativeMCPEndpoint.validate(endpoint)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              servers.count < 24,
              !servers.contains(where: { $0.endpoint == url.absoluteString })
        else { throw NativeMCPError.invalidResponse }
        let server = NativeMCPServer(id: UUID(), displayName: trimmed, endpoint: url.absoluteString)
        if let bearerToken { try credentials.save(bearerToken, for: server.id) }
        do {
            try Self.write(servers + [server], to: configURL)
        } catch {
            if bearerToken != nil { try? credentials.delete(for: server.id) }
            throw error
        }
        servers.append(server)
        try record(serverID: server.id, operation: "server.added")
        return server
    }

    /// Only the user's settings/consent action may call this; never model output.
    func setEnabled(_ enabled: Bool, serverID: UUID, consent: NativeMCPUserConsent) throws {
        _ = consent
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { throw NativeMCPError.missingServer }
        var updated = servers
        updated[index].enabled = enabled
        if !enabled { updated[index].enabledTools = [] }
        try Self.write(updated, to: configURL)
        servers = updated
        try record(serverID: serverID, operation: enabled ? "server.enabled" : "server.disabled")
    }

    /// The caller must additionally verify this exact name was discovered this session.
    func setToolEnabled(_ enabled: Bool, serverID: UUID, name: String,
                        consent: NativeMCPUserConsent) throws {
        _ = consent
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { throw NativeMCPError.missingServer }
        guard servers[index].enabled else { throw NativeMCPError.serverDisabled }
        var updated = servers
        if enabled { updated[index].enabledTools.insert(name) }
        else { updated[index].enabledTools.remove(name) }
        try Self.write(updated, to: configURL)
        servers = updated
        try record(serverID: serverID, operation: enabled ? "tool.enabled" : "tool.disabled", toolName: name)
    }

    func bearerToken(for serverID: UUID) throws -> String? {
        _ = try server(serverID)
        return try credentials.load(for: serverID)
    }

    func replaceBearerToken(_ token: String, serverID: UUID,
                            consent: NativeMCPUserConsent) throws {
        _ = consent
        _ = try server(serverID)
        try credentials.save(token, for: serverID)
        try record(serverID: serverID, operation: "credential.updated")
    }

    /// Disconnect first in NativeMCPConnector: no in-memory token or old session remains.
    func revokeCredential(serverID: UUID) throws {
        _ = try server(serverID)
        try credentials.delete(for: serverID)
        try record(serverID: serverID, operation: "credential.revoked")
    }

    func removeServer(_ id: UUID) throws {
        _ = try server(id)
        try credentials.delete(for: id)
        let updated = servers.filter { $0.id != id }
        try Self.write(updated, to: configURL)
        servers = updated
        try record(serverID: id, operation: "server.removed")
    }

    /// No token, URL, tool label, arguments, results, network error, or server text.
    func record(serverID: UUID, operation: String, toolName: String? = nil) throws {
        let fingerprint = toolName.map { name in
            SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let event = NativeMCPAuditEvent(id: UUID(), at: Date(), serverID: serverID,
                                        operation: operation, toolFingerprint: fingerprint)
        let updated = Array((events + [event]).suffix(500))
        try Self.write(updated, to: auditURL)
        events = updated
    }

    func auditEvents() -> [NativeMCPAuditEvent] { events }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
