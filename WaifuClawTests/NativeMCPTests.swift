import Foundation
import Security
import XCTest
@testable import WaifuClaw

private final class MCPFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var responder: ((URLRequest) -> (Int, [String: String], Data))?
    var redirectTo: URL?

    func append(_ request: URLRequest) { lock.lock(); captured.append(request); lock.unlock() }
    func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func reset() {
        lock.lock(); captured = []; responder = nil; redirectTo = nil; lock.unlock()
    }
}

private final class MCPFixtureProtocol: URLProtocol {
    static let state = MCPFixtureState()
    override class func canInit(with request: URLRequest) -> Bool {
        ["mcp.example.com", "other.example.com"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let length = buffer.count
                let count = stream.read(&buffer, maxLength: length)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            captured.httpBody = body
        }
        Self.state.append(captured)
        if let redirect = Self.state.redirectTo {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (status, headers, data) = Self.state.responder?(captured) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MCPMemoryCredentials: NativeMCPCredentialStore, @unchecked Sendable {
    private var tokens: [UUID: String] = [:]
    private let lock = NSLock()
    func save(_ token: String, for id: UUID) throws {
        _ = try NativeMCPKeychainCredentials.validated(token)
        lock.lock(); tokens[id] = token; lock.unlock()
    }
    func load(for id: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }; return tokens[id]
    }
    func delete(for id: UUID) throws { lock.lock(); tokens.removeValue(forKey: id); lock.unlock() }
}

final class NativeMCPTests: XCTestCase {
    private let endpoint = "https://mcp.example.com/mcp"

    func testLiveDeepWikiDiscoveryWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["WAIFUCLAW_LIVE_MCP"] == "1" else {
            throw XCTSkip("Set WAIFUCLAW_LIVE_MCP=1 to run an opt-in live public MCP interoperability test.")
        }
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(
            name: "Public DeepWiki",
            endpoint: "https://mcp.deepwiki.com/mcp"
        )
        let connector = NativeMCPConnector(registry: registry)
        let tools = try await connector.discover(serverID: server.id)
        XCTAssertTrue(tools.contains(where: { $0.name == "read_wiki_structure" }))
        XCTAssertTrue(tools.contains(where: { $0.name == "read_wiki_contents" }))
        await connector.disconnect(serverID: server.id)
    }

    private func fixtureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureProtocol.self]
        return configuration
    }

    private func store(_ credentials: MCPMemoryCredentials = MCPMemoryCredentials()) throws
        -> (NativeMCPRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try NativeMCPRegistry(directoryURL: dir, credentials: credentials), dir)
    }

    private func method(_ request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object["method"] as? String
    }

    private func parameter(_ key: String, request: URLRequest) -> Any? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return (object["params"] as? [String: Any])?[key]
    }

    private func response(for request: URLRequest, result: [String: Any]) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        return (try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": object?["id"] ?? "missing", "result": result
        ])) ?? Data()
    }

    private func installFixture(protocolVersion: String = "2025-11-25") {
        MCPFixtureProtocol.state.reset()
        MCPFixtureProtocol.state.responder = { [self] request in
            let headers = ["Content-Type": "application/json", "MCP-Session-Id": "fixture-session"]
            switch method(request) {
            case "initialize":
                return (200, headers, response(for: request, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "fixture", "version": "1.0"]
                ]))
            case "notifications/initialized": return (202, [:], Data())
            case "tools/list":
                let cursor = parameter("cursor", request: request) as? String
                let tool = cursor == nil ? "alpha" : "beta"
                return (200, ["Content-Type": "application/json"], response(for: request, result: [
                    "tools": [["name": tool, "description": "Remote/untrusted \(tool)",
                               "inputSchema": ["type": "object"]]],
                    "nextCursor": cursor == nil ? "next" : NSNull()
                ]))
            case "tools/call":
                return (200, ["Content-Type": "application/json"], response(for: request, result: [
                    "content": [["type": "text", "text": "Real remote fixture result"]],
                    "isError": true
                ]))
            default: return (404, [:], Data())
            }
        }
    }

    private func assertMCPError(_ expected: NativeMCPError, file: StaticString = #filePath,
                                line: UInt = #line, action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? NativeMCPError, expected, file: file, line: line) }
    }

    func testURLRejectsLocalPrivateLiteralAndUnsafeSchemes() throws {
        let denied = [
            "http://mcp.example.com/mcp", "file:///tmp/server", "https://localhost/mcp",
            "https://localhost.example.com/mcp", "https://127.0.0.1/mcp",
            "https://10.0.0.3/mcp", "https://[::1]/mcp", "https://[fc00::1]/mcp",
            "https://2130706433/mcp", "https://mcp.local/mcp",
            "https://user:password@mcp.example.com/mcp", "https://mcp.example.com:8080/mcp",
            "https://mcp.example.com/mcp#fragment", "https://mcp.example.com/mcp?token=x"
        ]
        for url in denied {
            XCTAssertThrowsError(try NativeMCPEndpoint.validate(url), url)
        }
        XCTAssertEqual(try NativeMCPEndpoint.validate(endpoint).absoluteString, endpoint)
    }

    func testVersionMismatchRejectedBeforeInitializedNotification() async throws {
        installFixture(protocolVersion: "2026-07-28")
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(name: "Sample", endpoint: endpoint)
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        await assertMCPError(.unsupportedVersion) { _ = try await connector.discover(serverID: server.id) }
        XCTAssertFalse(MCPFixtureProtocol.state.requests().contains(where: { method($0) == "notifications/initialized" }))
    }

    func testPOSTSSEInitializeAndToolPage() async throws {
        installFixture()
        MCPFixtureProtocol.state.responder = { [self] request in
            if method(request) == "notifications/initialized" { return (202, [:], Data()) }
            let result: [String: Any]
            switch method(request) {
            case "initialize":
                result = ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "fixture", "version": "1.0"]]
            case "tools/list":
                result = ["tools": [["name": "sse_tool", "inputSchema": ["type": "object"]]]]
            default: return (404, [:], Data())
            }
            let json = String(decoding: response(for: request, result: result), as: UTF8.self)
            return (200, ["Content-Type": "text/event-stream", "MCP-Session-Id": "sse-session"],
                    Data("event: message\ndata: \(json)\n\n".utf8))
        }
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(name: "SSE", endpoint: endpoint)
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        let tools = try await connector.discover(serverID: server.id)
        XCTAssertEqual(tools.map(\.name), ["sse_tool"])
        let pageRequest = try XCTUnwrap(MCPFixtureProtocol.state.requests().first(where: {
            method($0) == "tools/list"
        }))
        XCTAssertEqual(pageRequest.value(forHTTPHeaderField: "MCP-Session-Id"), "sse-session")
        await connector.disconnect(serverID: server.id)
    }

    func testPaginationAllowlistExactArgumentsOneUseAndErrorResult() async throws {
        installFixture()
        let credentials = MCPMemoryCredentials()
        let (registry, directory) = try store(credentials)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "secret-not-for-audit-987"
        let server = try await registry.addServer(name: "Sample", endpoint: endpoint, bearerToken: token)
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        let discovered = try await connector.discover(serverID: server.id)
        XCTAssertEqual(discovered.map(\.name), ["alpha", "beta"])
        let beforeEnabled = await connector.modelTools()
        XCTAssertTrue(beforeEnabled.isEmpty)
        let consent = NativeMCPUserConsent.explicitUserApproval
        try await connector.setServerEnabled(true, serverID: server.id, consent: consent)
        let beforeToolEnabled = await connector.modelTools()
        XCTAssertTrue(beforeToolEnabled.isEmpty)
        try await connector.setToolEnabled(true, serverID: server.id, name: "alpha", consent: consent)
        let offered = await connector.modelTools()
        XCTAssertEqual(offered.map(\.name), ["alpha"])
        await assertMCPError(.toolNotEnabled) {
            _ = try await connector.approveToolCall(serverID: server.id, name: "beta",
                                                    argumentsJSON: "{}", consent: consent)
        }
        await assertMCPError(.invalidArguments) {
            _ = try await connector.approveToolCall(serverID: server.id, name: "alpha",
                                                    argumentsJSON: "[1]", consent: consent)
        }
        let approved = try await connector.approveToolCall(serverID: server.id, name: "alpha",
                            argumentsJSON: "{\"n\":1,\"nested\":{\"ok\":true}}", consent: consent)
        let result = try await connector.executeToolCall(approved)
        XCTAssertEqual(result.text, "Real remote fixture result")
        XCTAssertTrue(result.isError)
        await assertMCPError(.revokedCall) { _ = try await connector.executeToolCall(approved) }
        await assertMCPError(.revokedCall) {
            _ = try await connector.executeToolCall(.issued(id: UUID()))
        }
        let sent = MCPFixtureProtocol.state.requests()
        XCTAssertTrue(sent.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertEqual(sent.compactMap { method($0) },
                       ["initialize", "notifications/initialized", "tools/list", "tools/list", "tools/call"])
        let call = try XCTUnwrap(sent.first(where: { method($0) == "tools/call" }))
        XCTAssertEqual(parameter("name", request: call) as? String, "alpha")
        let arguments = try XCTUnwrap(parameter("arguments", request: call) as? [String: Any])
        XCTAssertEqual(arguments["n"] as? Int, 1)
        XCTAssertEqual((arguments["nested"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(call.value(forHTTPHeaderField: "MCP-Session-Id"), "fixture-session")
        XCTAssertEqual(call.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-11-25")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let audit = try String(contentsOf: directory.appendingPathComponent("audit.json"), encoding: .utf8)
        let servers = try String(contentsOf: directory.appendingPathComponent("servers.json"), encoding: .utf8)
        XCTAssertFalse(audit.contains(token))
        XCTAssertFalse(servers.contains(token))
        XCTAssertFalse(audit.contains("Real remote fixture result"))
        XCTAssertFalse(audit.contains("nested"))
        let restored = try NativeMCPRegistry(directoryURL: directory, credentials: credentials)
        let restoredServer = try await restored.server(server.id)
        XCTAssertEqual(restoredServer.enabledTools, Set(["alpha"]))
        let restoredEvents = await restored.auditEvents()
        XCTAssertTrue(restoredEvents.contains(where: { $0.operation == "tool.call.completed" }))
        await connector.disconnect(serverID: server.id)
    }

    func testRepeatedPaginationCursorIsBounded() async throws {
        installFixture()
        MCPFixtureProtocol.state.responder = { [self] request in
            switch method(request) {
            case "initialize":
                return (200, ["Content-Type": "application/json"], response(for: request, result: [
                    "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "fixture", "version": "1"]
                ]))
            case "notifications/initialized": return (202, [:], Data())
            case "tools/list":
                return (200, ["Content-Type": "application/json"], response(for: request,
                        result: ["tools": [], "nextCursor": "same-cursor"]))
            default: return (404, [:], Data())
            }
        }
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(name: "Loop", endpoint: endpoint)
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        await assertMCPError(.tooManyTools) { _ = try await connector.discover(serverID: server.id) }
        XCTAssertEqual(MCPFixtureProtocol.state.requests().filter { method($0) == "tools/list" }.count, 2)
    }

    func testRejectsRedirectWithoutFollowingOrForwardingToken() async throws {
        installFixture()
        MCPFixtureProtocol.state.redirectTo = URL(string: "https://other.example.com/steal")!
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(name: "R", endpoint: endpoint,
                                                  bearerToken: "redirect-secret")
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        do { _ = try await connector.discover(serverID: server.id); XCTFail("Redirect must fail") }
        catch { /* URLSession may surface a 302 or a cancelled redirect; both fail closed. */ }
        XCTAssertEqual(MCPFixtureProtocol.state.requests().count, 1)
        XCTAssertEqual(MCPFixtureProtocol.state.requests().first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer redirect-secret")
        XCTAssertFalse(MCPFixtureProtocol.state.requests().contains(where: {
            $0.url?.host == "other.example.com"
        }))
    }

    func testResponseCapAndCredentialRevocation() async throws {
        installFixture()
        let (registry, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await registry.addServer(name: "S", endpoint: endpoint,
                                                  bearerToken: "fixture-token-to-revoke")
        let connector = NativeMCPConnector(registry: registry, configuration: fixtureConfiguration())
        _ = try await connector.discover(serverID: server.id)
        try await connector.revokeCredential(serverID: server.id)
        let erasedToken = try await registry.bearerToken(for: server.id)
        XCTAssertNil(erasedToken)
        _ = try await connector.discover(serverID: server.id)
        let latest = try XCTUnwrap(MCPFixtureProtocol.state.requests().last(where: { method($0) == "initialize" }))
        XCTAssertNil(latest.value(forHTTPHeaderField: "Authorization"))
        await connector.disconnect(serverID: server.id)
        MCPFixtureProtocol.state.responder = { _ in
            (200, ["Content-Type": "application/json"], Data(repeating: 65, count: 256 * 1024 + 1))
        }
        await assertMCPError(.responseTooLarge) { _ = try await connector.discover(serverID: server.id) }
    }

    func testActualKeychainDeleteWhenSimulatorPermits() throws {
        let store = NativeMCPKeychainCredentials(service: "studio.phantomhorizons.waifuclaw.tests.mcp.\(UUID())")
        let serverID = UUID()
        defer { try? store.delete(for: serverID) }
        do {
            try store.save("secret-that-must-be-revoked", for: serverID)
            XCTAssertEqual(try store.load(for: serverID), "secret-that-must-be-revoked")
            try store.delete(for: serverID)
            XCTAssertNil(try store.load(for: serverID))
        } catch let error as NativeMCPKeychainCredentials.CredentialError {
            if case .status(let status) = error,
               [errSecNotAvailable, errSecInteractionNotAllowed, errSecMissingEntitlement].contains(status) {
                throw XCTSkip("Unsigned or locked simulator cannot access Keychain: \(status)")
            }
            throw error
        }
    }
}
