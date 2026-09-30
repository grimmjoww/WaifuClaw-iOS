import Foundation
import MCP

/// This slice intentionally supports only remote HTTPS Streamable HTTP at MCP 2025-11-25.
/// No stdio, local/HTTP servers, OAuth discovery, or 2026-only request metadata.
enum NativeMCPError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, invalidToken, missingServer, serverDisabled, missingConnection
    case unsupportedVersion, invalidResponse, responseTooLarge, badStatus(Int)
    case tooManyTools, duplicateTool, toolNotDiscovered, toolNotEnabled
    case invalidArguments, unauthorizedCall, revokedCall, invalidSession

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a public HTTPS domain and a port of 443. Local network endpoints are unavailable."
        case .invalidToken: "Enter a bearer token without control characters (at most 4096 characters)."
        case .missingServer: "This MCP server was removed."
        case .serverDisabled: "Enable this MCP server before exposing tools or calling them."
        case .missingConnection: "Connect and discover tools before calling them."
        case .unsupportedVersion: "This server did not negotiate MCP 2025-11-25. Newer-only servers are unsupported."
        case .invalidResponse: "The MCP server sent an invalid response."
        case .responseTooLarge: "The MCP response exceeded the 256 KiB limit."
        case .badStatus(let status): status == 401 || status == 403
            ? "MCP authorization failed (HTTP \(status)). OAuth-only servers are unsupported."
            : "MCP request failed (HTTP \(status))."
        case .tooManyTools: "The MCP tool catalog exceeded the allowed pagination or size limit."
        case .duplicateTool: "The MCP catalog repeated a tool name."
        case .toolNotDiscovered: "That exact tool name is not in the current discovered catalog."
        case .toolNotEnabled: "This tool is not explicitly enabled."
        case .invalidArguments: "Tool arguments must be a JSON object of at most 32 KiB."
        case .unauthorizedCall: "A matching, user-approved tool call is required."
        case .revokedCall: "This approval expired or was already used."
        case .invalidSession: "The MCP session identifier was invalid or changed."
        }
    }
}

/// Do not turn this into a general URI client. An HTTPS URL does not guarantee that
/// its DNS answer remains public: URLSession DNS re-resolution/rebinding is a known
/// remaining limitation; network-layer address checks would require a separate design.
enum NativeMCPEndpoint {
    static func validate(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 2048, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.fragment == nil,
              components.query == nil, components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), host.utf8.count <= 253,
              !host.hasSuffix("."), !host.contains(":"), !host.contains("%"),
              let url = components.url, url.scheme?.lowercased() == "https"
        else { throw NativeMCPError.invalidURL }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              !["localhost", "local", "internal", "test", "invalid", "example"].contains(String(labels.last!)),
              !["localhost", "local", "internal", "home", "lan"].contains(String(labels.first!)),
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { byte in
                      (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 45
                  }
              }),
              labels.last!.utf8.contains(where: { (97...122).contains($0) })
        else { throw NativeMCPError.invalidURL }
        // All literal IPv4/IPv6 addresses, integer/octal/hex aliases, and single-label
        // hosts are rejected, even when a literal address would otherwise be public.
        return url
    }
}

struct NativeMCPServer: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let displayName: String // User-entered; never supplied by the server.
    let endpoint: String
    var enabled: Bool = false
    var enabledTools: Set<String> = []
}

/// These strings are UNTRUSTED server data for display only. Not a model tool offer.
struct NativeMCPDiscoveredTool: Sendable, Equatable {
    let name: String
    let title: String?
    let description: String?
}

/// Only produce after both server and exact tool have been explicitly enabled.
/// The schema and description remain untrusted server data, never instructions.
struct NativeMCPModelTool: Sendable {
    let serverID: UUID
    let name: String
    let description: String?
    let inputSchema: MCP.Value
}

/// This approval is issued ONLY from the UI's explicit human consent callback;
/// it cannot be constructed by parsing a model-proposed call.
enum NativeMCPUserConsent: Sendable { case explicitUserApproval }

/// One-use capability; its arguments/name/server are checked against the private
/// pending request at execution time. Never persist or expose it to the model.
struct NativeMCPApprovedCall: Sendable {
    let id: UUID
    fileprivate init(id: UUID) { self.id = id }
    static func issued(id: UUID) -> Self { .init(id: id) }
}

struct NativeMCPCallResult: Sendable, Equatable {
    let text: String
    let isError: Bool
    let omittedNonTextContent: Bool
}

/// Intentionally no remote URL, headers, argument values, result bodies or raw errors.
struct NativeMCPAuditEvent: Codable, Sendable, Equatable {
    let id: UUID
    let at: Date
    let serverID: UUID
    let operation: String
    let toolFingerprint: String? // SHA-256 of name, never a server-supplied string.
}
