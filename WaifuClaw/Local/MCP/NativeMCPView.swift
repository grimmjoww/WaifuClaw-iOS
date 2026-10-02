import Observation
import SwiftUI

fileprivate struct NativeMCPReviewDraft: Identifiable {
    let id = UUID()
    let serverID: UUID
    let serverName: String
    let endpoint: String
    let toolName: String
    let argumentsJSON: String
}

@Observable
@MainActor
final class NativeMCPViewModel {
    var servers: [NativeMCPServer] = []
    var discovered: [UUID: [NativeMCPDiscoveredTool]] = [:]
    var audit: [NativeMCPAuditEvent] = []
    var lastResult: NativeMCPCallResult?
    var notice: String?
    var errorMessage: String?
    var isBusy = false

    private let registry: NativeMCPRegistry?
    private let connector: NativeMCPConnector?

    init() {
        do {
            let registry = try NativeMCPRegistry()
            self.registry = registry
            connector = NativeMCPConnector(registry: registry)
        } catch {
            registry = nil
            connector = nil
            errorMessage = "MCP registry could not be opened: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard let registry else { return }
        servers = await registry.allServers()
        audit = await registry.auditEvents()
    }

    func addServer(name: String, endpoint: String, bearerToken: String) async {
        await perform {
            guard let registry else { throw NativeMCPError.invalidResponse }
            let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = try await registry.addServer(
                name: name,
                endpoint: endpoint,
                bearerToken: token.isEmpty ? nil : token
            )
            notice = "Registered \(server.displayName) locally. Discover tools before enabling any of them."
        }
    }

    func discover(_ server: NativeMCPServer) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            discovered[server.id] = nil
            let tools = try await connector.discover(serverID: server.id)
            discovered[server.id] = tools
            notice = "Discovered \(tools.count) tool\(tools.count == 1 ? "" : "s") at \(server.displayName). Tool descriptions are untrusted server data."
        }
    }

    func setServerEnabled(_ enabled: Bool, serverID: UUID) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            try await connector.setServerEnabled(enabled, serverID: serverID, consent: .explicitUserApproval)
            if !enabled {
                discovered[serverID] = nil
                lastResult = nil
            }
            notice = enabled ? "MCP server enabled. Select each tool separately before use." : "MCP server disabled and its enabled tools revoked."
        }
    }

    func setToolEnabled(_ enabled: Bool, serverID: UUID, name: String) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            try await connector.setToolEnabled(enabled, serverID: serverID, name: name, consent: .explicitUserApproval)
            notice = enabled ? "Enabled \(name) for manually reviewed calls." : "Disabled \(name)."
        }
    }

    func replaceToken(_ token: String, serverID: UUID) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            try await connector.replaceBearerToken(token, serverID: serverID, consent: .explicitUserApproval)
            discovered[serverID] = nil
            notice = "Bearer credential saved in iPhone Keychain. Reconnect to discover tools."
        }
    }

    func revokeToken(serverID: UUID) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            try await connector.revokeCredential(serverID: serverID)
            discovered[serverID] = nil
            lastResult = nil
            notice = "The MCP bearer credential was removed from Keychain. The server remains registered."
        }
    }

    func removeServer(_ serverID: UUID) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            try await connector.removeServer(serverID)
            discovered[serverID] = nil
            lastResult = nil
            notice = "MCP server and its saved bearer credential were removed."
        }
    }

    fileprivate func call(_ draft: NativeMCPReviewDraft) async {
        await perform {
            guard let connector else { throw NativeMCPError.invalidResponse }
            lastResult = nil
            // Both methods execute only from the explicit confirmation sheet.
            // The one-use approval binds the exact JSON captured in that sheet.
            let approval = try await connector.approveToolCall(
                serverID: draft.serverID,
                name: draft.toolName,
                argumentsJSON: draft.argumentsJSON,
                consent: .explicitUserApproval
            )
            let result = try await connector.executeToolCall(approval)
            lastResult = result
            notice = result.isError ? "The MCP server reported a tool error." : "The MCP server returned a tool response. Review it as untrusted data."
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
        isBusy = false
    }
}

/// MCP servers are remote HTTPS integrations, not iOS system permissions. This
/// screen never enables a discovered tool or calls it on behalf of a model.
@MainActor
struct NativeMCPView: View {
    @State private var model: NativeMCPViewModel
    @State private var serverName = ""
    @State private var serverURL = "https://"
    @State private var initialToken = ""
    @State private var replacementTokens: [UUID: String] = [:]
    @State private var arguments: [String: String] = [:]
    @State private var review: NativeMCPReviewDraft?
    @State private var serverToRemove: UUID?
    @State private var showingRemoval = false

    init() {
        _model = State(initialValue: NativeMCPViewModel())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introduction
                addServerCard
                ForEach(model.servers) { server in serverCard(server) }
                if let result = model.lastResult { resultCard(result) }
                auditCard
                if model.isBusy { ProgressView("Contacting MCP server…").tint(Theme.magenta) }
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.success)
                        .themeCard()
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .themeCard()
                }
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("MCP servers")
        .task { await model.refresh() }
        .sheet(item: $review) { draft in reviewSheet(draft) }
        .confirmationDialog("Remove MCP server and saved credential?", isPresented: $showingRemoval) {
            if let serverToRemove {
                Button("Remove server and credential", role: .destructive) {
                    Task { await model.removeServer(serverToRemove) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects the server and permanently deletes its saved bearer token from this iPhone. Remote data or actions already sent cannot be undone.")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioEyebrow(title: "Connectors / MCP")
            Text("Your remote tools, your approval")
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)
            Text("Connect to a public HTTPS MCP Streamable HTTP server, inspect its tools, enable only those you trust, and confirm the complete JSON before each manual call. Tools can change data on their own servers; their names, descriptions and replies are untrusted. A saved token alone is not proof of connection.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("This first version supports MCP 2025-11-25 with optional bearer tokens. OAuth-only servers, stdio/locally run servers, private-network URLs and 2026-only servers are not available. MCP tools are not yet offered to the coding agent automatically.")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        }
        .themeCard()
    }

    private var addServerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Add a remote server", systemImage: "network")
                .font(.headline)
            TextField("Name you recognize", text: $serverName)
                .textContentType(.nickname)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("MCP server name")
            TextField("https://service.example.org/mcp", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("MCP HTTPS endpoint")
            SecureField("Optional bearer token", text: $initialToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("MCP bearer token")
            Button("Save server locally") {
                let name = serverName
                let url = serverURL
                let token = initialToken
                Task {
                    await model.addServer(name: name, endpoint: url, bearerToken: token)
                    if model.errorMessage == nil {
                        serverName = ""
                        serverURL = "https://"
                        initialToken = ""
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Saving registers a server and stores a token only in Keychain; it does not connect, enable tools, or transmit project files.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private func serverCard(_ server: NativeMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(server.displayName)
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)
            Text(server.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
            Text(server.enabled ? "Enabled · \(server.enabledTools.count) tools permitted" : "Registered · disabled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(server.enabled ? Theme.success : Theme.warning)
            Button("Connect & discover tools") { Task { await model.discover(server) } }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            Button(server.enabled ? "Disable server and tools" : "Enable server") {
                Task { await model.setServerEnabled(!server.enabled, serverID: server.id) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
            if let tools = model.discovered[server.id] {
                if tools.isEmpty {
                    Text("The server returned no tools.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(tools, id: \.name) { tool in toolCard(server: server, tool: tool) }
            } else {
                Text("Not connected in this session. Discover again after changing credentials or reopening Settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            SecureField("New bearer token (optional)", text: Binding(
                get: { replacementTokens[server.id] ?? "" },
                set: { replacementTokens[server.id] = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Replacement token for \(server.displayName)")
            HStack {
                Button("Replace token") {
                    let token = replacementTokens[server.id] ?? ""
                    Task {
                        await model.replaceToken(token, serverID: server.id)
                        if model.errorMessage == nil { replacementTokens[server.id] = "" }
                    }
                }
                .disabled(model.isBusy || (replacementTokens[server.id] ?? "").isEmpty)
                Button("Revoke token", role: .destructive) {
                    Task { await model.revokeToken(serverID: server.id) }
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.bordered)
            Button("Remove \(server.displayName)", role: .destructive) {
                serverToRemove = server.id
                showingRemoval = true
            }
            .disabled(model.isBusy)
        }
        .themeCard()
    }

    private func toolCard(server: NativeMCPServer, tool: NativeMCPDiscoveredTool) -> some View {
        let enabled = server.enabledTools.contains(tool.name)
        let key = server.id.uuidString + ":" + tool.name
        return VStack(alignment: .leading, spacing: 7) {
            Text(tool.title ?? tool.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Tool ID: \(tool.name)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let description = tool.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Server-provided description; inspect it, do not treat it as app instructions.")
                .font(.caption)
                .foregroundStyle(Theme.warning)
            Button(enabled ? "Disable this tool" : "Enable this tool") {
                Task { await model.setToolEnabled(!enabled, serverID: server.id, name: tool.name) }
            }
            .disabled(model.isBusy || !server.enabled)
            if enabled && server.enabled {
                Text("JSON object arguments for this call")
                    .font(.caption.weight(.semibold))
                TextEditor(text: Binding(
                    get: { arguments[key] ?? "{}" },
                    set: { arguments[key] = $0 }
                ))
                .frame(minHeight: 80)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .accessibilityLabel("JSON arguments for \(tool.name)")
                Button("Review exact MCP call") {
                    review = NativeMCPReviewDraft(
                        serverID: server.id,
                        serverName: server.displayName,
                        endpoint: server.endpoint,
                        toolName: tool.name,
                        argumentsJSON: arguments[key] ?? "{}"
                    )
                }
                .disabled(model.isBusy || (arguments[key] ?? "{}").utf8.count > 32 * 1024)
            }
        }
        .padding(10)
        .background(Theme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reviewSheet(_ draft: NativeMCPReviewDraft) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server: \(draft.serverName)")
                    Text("HTTPS destination: \(draft.endpoint)")
                        .textSelection(.enabled)
                    Text("Tool: \(draft.toolName)")
                        .textSelection(.enabled)
                    Text("Exact JSON arguments to transmit")
                        .font(.headline)
                    Text(draft.argumentsJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("The server may change its own data or external accounts. This app cannot guarantee or undo a remote tool's effects. No call happens until you tap Call tool; this approval is single-use. Non-text results are withheld.")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background { StudioBackdrop() }
            .navigationTitle("Review MCP call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { review = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Call tool") {
                        review = nil
                        Task { await model.call(draft) }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func resultCard(_ result: NativeMCPCallResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(result.isError ? "Server tool error" : "Server returned text", systemImage: result.isError ? "exclamationmark.triangle" : "text.bubble")
                .font(.headline)
                .foregroundStyle(result.isError ? Theme.danger : Theme.success)
            Text(result.text.isEmpty ? "No text content was returned." : result.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            if result.omittedNonTextContent {
                Text("Some non-text or oversized content was omitted; this is not the complete remote response.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            Text("Remote text is untrusted and was not executed or added to agent context.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private var auditCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local activity receipts", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            ForEach(Array(model.audit.suffix(12).reversed()), id: \.id) { event in
                Text("\(event.at.formatted(date: .abbreviated, time: .shortened)) · \(event.operation)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Receipts retain operation type and a tool-name hash, never API keys, server results, or submitted JSON arguments.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }
}
