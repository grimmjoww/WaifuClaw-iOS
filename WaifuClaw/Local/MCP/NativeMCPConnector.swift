import Foundation
import MCP

/// Remote MCP facade for Settings/UI. Models must never receive this actor or call
/// approveToolCall: UI issues each one-use approval after showing the exact JSON.
actor NativeMCPConnector {
    private struct Connection: Sendable {
        let client: MCP.Client
        let transport: NativeMCPTransport
        let tools: [String: MCP.Tool]
    }
    private struct Pending: Sendable {
        let serverID: UUID
        let name: String
        let arguments: [String: MCP.Value]
        let generation: Int
    }

    let registry: NativeMCPRegistry
    private let configuration: URLSessionConfiguration
    private var connections: [UUID: Connection] = [:]
    private var generations: [UUID: Int] = [:]
    private var pending: [UUID: Pending] = [:]
    private var blocked: Set<UUID> = []

    init(registry: NativeMCPRegistry, configuration: URLSessionConfiguration = .ephemeral) {
        self.registry = registry
        self.configuration = configuration
    }

    /// Discovery is for the Settings UI only, not model context. A registered
    /// disabled server may be discovered to show the user what they might enable.
    func discover(serverID: UUID) async throws -> [NativeMCPDiscoveredTool] {
        guard !blocked.contains(serverID) else { throw NativeMCPError.missingServer }
        await disconnect(serverID: serverID)
        let revision = generations[serverID, default: 0]
        let server = try await registry.server(serverID)
        let endpoint = try NativeMCPEndpoint.validate(server.endpoint)
        let token = try await registry.bearerToken(for: serverID)
        let transport = try NativeMCPTransport(endpoint: endpoint, token: token,
                                               configuration: configuration.copy() as? URLSessionConfiguration ?? .ephemeral)
        let client = MCP.Client(name: "WaifuClaw", version: "1.0.0", configuration: .strict)
        do {
            let initialized = try await client.connect(transport: transport)
            guard initialized.protocolVersion == "2025-11-25" else { throw NativeMCPError.unsupportedVersion }
            var all: [String: MCP.Tool] = [:]
            var cursor: String?
            var cursors: Set<String> = []
            var finished = false
            for _ in 0..<4 {
                try Task.checkCancellation()
                let page = try await client.listTools(cursor: cursor)
                guard all.count + page.tools.count <= 80 else { throw NativeMCPError.tooManyTools }
                for tool in page.tools {
                    guard !tool.name.isEmpty, tool.name.utf8.count <= 128,
                          tool.name.utf8.allSatisfy({ byte in
                              (65...90).contains(byte) || (97...122).contains(byte) ||
                              (48...57).contains(byte) || [45, 46, 47, 95].contains(byte)
                          }),
                          all[tool.name] == nil,
                          case .object(let schema) = tool.inputSchema,
                          schema["type"] == .string("object")
                    else { throw NativeMCPError.invalidResponse }
                    all[tool.name] = tool
                }
                guard let next = page.nextCursor else { finished = true; break }
                guard !next.isEmpty, next.utf8.count <= 256, cursors.insert(next).inserted else {
                    throw NativeMCPError.tooManyTools
                }
                cursor = next
            }
            guard finished else { throw NativeMCPError.tooManyTools }
            try await registry.record(serverID: serverID, operation: "tools.discovered")
            guard generations[serverID] == revision, !blocked.contains(serverID),
                  (try await registry.server(serverID)).endpoint == server.endpoint
            else { throw NativeMCPError.missingConnection }
            connections[serverID] = Connection(client: client, transport: transport, tools: all)
            return all.values.sorted(by: { $0.name < $1.name }).map {
                NativeMCPDiscoveredTool(name: $0.name,
                                        title: $0.title.map { String($0.prefix(120)) },
                                        description: $0.description.map { String($0.prefix(600)) })
            }
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func setServerEnabled(_ enabled: Bool, serverID: UUID,
                          consent: NativeMCPUserConsent) async throws {
        if !enabled { await disconnect(serverID: serverID) }
        try await registry.setEnabled(enabled, serverID: serverID, consent: consent)
    }

    func setToolEnabled(_ enabled: Bool, serverID: UUID, name: String,
                        consent: NativeMCPUserConsent) async throws {
        guard connections[serverID]?.tools[name] != nil else { throw NativeMCPError.toolNotDiscovered }
        if !enabled { pending = pending.filter { $0.value.serverID != serverID || $0.value.name != name } }
        try await registry.setToolEnabled(enabled, serverID: serverID, name: name, consent: consent)
    }

    /// Call only after explicit enablement. These are the ONLY labels/schemas
    /// that may become model-visible; never use the discovery UI list for this.
    func modelTools() async -> [NativeMCPModelTool] {
        let servers = await registry.allServers()
        return servers.filter(\.enabled).flatMap { server in
            guard let connection = connections[server.id] else { return [NativeMCPModelTool]() }
            return server.enabledTools.sorted().compactMap { name in
                guard let tool = connection.tools[name] else { return nil }
                return NativeMCPModelTool(serverID: server.id, name: name,
                                          description: tool.description.map { String($0.prefix(600)) },
                                          inputSchema: tool.inputSchema)
            }
        }
    }

    /// UI displays endpoint + exact name + complete JSON object, THEN collects
    /// user consent. Never synthesize consent from a model's request or prompt.
    func approveToolCall(serverID: UUID, name: String, argumentsJSON: String,
                         consent: NativeMCPUserConsent) async throws -> NativeMCPApprovedCall {
        _ = consent
        let arguments = try Self.decodeObject(argumentsJSON)
        guard let connection = connections[serverID] else { throw NativeMCPError.missingConnection }
        guard connection.tools[name] != nil else { throw NativeMCPError.toolNotDiscovered }
        let server = try await registry.server(serverID)
        guard server.enabled else { throw NativeMCPError.serverDisabled }
        guard server.enabledTools.contains(name) else { throw NativeMCPError.toolNotEnabled }
        guard !blocked.contains(serverID), connections[serverID] != nil else { throw NativeMCPError.missingConnection }
        let id = UUID()
        let revision = generations[serverID, default: 0]
        try await registry.record(serverID: serverID, operation: "tool.call.approved", toolName: name)
        guard generations[serverID, default: 0] == revision, !blocked.contains(serverID),
              connections[serverID] != nil else { throw NativeMCPError.revokedCall }
        pending[id] = Pending(serverID: serverID, name: name,
                              arguments: arguments, generation: revision)
        return .issued(id: id)
    }

    /// One-use receipt is consumed BEFORE the remote request. The name and JSON
    /// arguments are never taken from a model or altered between approval and call.
    func executeToolCall(_ approved: NativeMCPApprovedCall) async throws -> NativeMCPCallResult {
        guard let request = pending.removeValue(forKey: approved.id) else { throw NativeMCPError.revokedCall }
        guard !blocked.contains(request.serverID),
              generations[request.serverID, default: 0] == request.generation,
              let connection = connections[request.serverID],
              connection.tools[request.name] != nil
        else { throw NativeMCPError.revokedCall }
        let server = try await registry.server(request.serverID)
        guard server.enabled, server.enabledTools.contains(request.name) else {
            throw NativeMCPError.toolNotEnabled
        }
        guard generations[request.serverID, default: 0] == request.generation else {
            throw NativeMCPError.revokedCall
        }
        // Fail closed if the durable audit cannot record a pending network side effect.
        try await registry.record(serverID: request.serverID, operation: "tool.call.started",
                                  toolName: request.name)
        do {
            let raw: (content: [MCP.Tool.Content], isError: Bool?) = try await connection.client.callTool(
                name: request.name, arguments: request.arguments
            )
            var text = ""
            var omitted = false
            for part in raw.content {
                switch part {
                case .text(let content, _, _):
                    if !text.isEmpty, text.utf8.count < 16_384 { text += "\n" }
                    let space = max(0, 16_384 - text.utf8.count)
                    var chunk = ""
                    var used = 0
                    for scalar in content.unicodeScalars {
                        let character = String(scalar)
                        let bytes = character.utf8.count
                        if used + bytes > space { break }
                        chunk += character
                        used += bytes
                    }
                    text += chunk
                    if used < content.utf8.count { omitted = true }
                default:
                    omitted = true // Never pass through image/audio/resource bytes or URLs.
                }
            }
            guard generations[request.serverID, default: 0] == request.generation else {
                throw NativeMCPError.revokedCall
            }
            try await registry.record(serverID: request.serverID, operation: "tool.call.completed",
                                      toolName: request.name)
            return NativeMCPCallResult(text: text, isError: raw.isError == true,
                                       omittedNonTextContent: omitted)
        } catch {
            try? await registry.record(serverID: request.serverID, operation: "tool.call.failed",
                                       toolName: request.name)
            throw error
        }
    }

    func disconnect(serverID: UUID) async {
        generations[serverID, default: 0] += 1
        pending = pending.filter { $0.value.serverID != serverID }
        if let connection = connections.removeValue(forKey: serverID) {
            await connection.client.disconnect()
        }
        try? await registry.record(serverID: serverID, operation: "server.disconnected")
    }

    func revokeCredential(serverID: UUID) async throws {
        blocked.insert(serverID)
        defer { blocked.remove(serverID) }
        await disconnect(serverID: serverID)
        try await registry.revokeCredential(serverID: serverID)
    }

    func replaceBearerToken(_ token: String, serverID: UUID,
                            consent: NativeMCPUserConsent) async throws {
        blocked.insert(serverID)
        defer { blocked.remove(serverID) }
        await disconnect(serverID: serverID)
        try await registry.replaceBearerToken(token, serverID: serverID, consent: consent)
    }

    func removeServer(_ id: UUID) async throws {
        blocked.insert(id)
        defer { blocked.remove(id) }
        await disconnect(serverID: id)
        try await registry.removeServer(id)
    }

    private static func decodeObject(_ json: String) throws -> [String: MCP.Value] {
        guard json.utf8.count <= 32 * 1024,
              let value = try? JSONDecoder().decode(MCP.Value.self, from: Data(json.utf8)),
              case .object(let object) = value
        else { throw NativeMCPError.invalidArguments }
        return object
    }
}
