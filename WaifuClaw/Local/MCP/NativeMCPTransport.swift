import Foundation
import Logging
import MCP

/// URLSession never follows a redirect, including one to a different public host.
/// This also blocks accidental bearer forwarding to a redirected private endpoint.
final class NativeMCPNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// POST-only 2025-11-25 Streamable HTTP. No GET SSE, OAuth metadata requests,
/// automatic retry, local process, or generic HTTP client is reachable here.
actor NativeMCPTransport: MCP.Transport {
    nonisolated let logger = Logger(label: "waifuclaw.mcp.transport", factory: { _ in
        SwiftLogNoOpLogHandler() // Never log raw SDK payloads, URLs or Authorization.
    })

    static let maximumResponseBytes = 256 * 1024
    private let endpoint: URL
    private let token: String?
    private let session: URLSession
    private let redirectBlocker: NativeMCPNoRedirects
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var isConnected = false
    private var requestActive = false
    private var sessionID: String?
    private var negotiatedVersion: String?

    init(endpoint: URL, token: String?, configuration: URLSessionConfiguration = .ephemeral) throws {
        _ = try NativeMCPEndpoint.validate(endpoint.absoluteString)
        if let token { _ = try NativeMCPKeychainCredentials.validated(token) }
        self.endpoint = endpoint
        self.token = token
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        let blocker = NativeMCPNoRedirects()
        redirectBlocker = blocker
        self.session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
        var yielded: AsyncThrowingStream<Data, Error>.Continuation!
        messages = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { yielded = $0 }
        continuation = yielded
    }

    func connect() async throws { isConnected = true }
    func disconnect() async {
        isConnected = false
        session.invalidateAndCancel()
        continuation.finish()
    }
    func receive() -> AsyncThrowingStream<Data, Error> { messages }

    func send(_ data: Data) async throws {
        guard isConnected, !requestActive else { throw NativeMCPError.missingConnection }
        guard data.count <= 64 * 1024,
              let outgoing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = outgoing["method"] as? String,
              (outgoing["id"] == nil || outgoing["id"] is String)
        else { throw NativeMCPError.invalidArguments }
        let expectedID = outgoing["id"] as? String
        let isInitialize = method == "initialize"
        requestActive = true
        defer { requestActive = false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedVersion ?? "2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectBlocker)
        guard isConnected, let http = response as? HTTPURLResponse else { throw NativeMCPError.invalidResponse }
        // URLSession's redirect delegate returned nil. 3xx is a terminal failure.
        guard http.statusCode == 200 || (http.statusCode == 202 && expectedID == nil) else {
            throw NativeMCPError.badStatus(http.statusCode)
        }
        guard let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
              contentLength <= Self.maximumResponseBytes || http.statusCode == 202
        else {
            // Missing Content-Length is legal for streaming/chunked responses.
            if http.value(forHTTPHeaderField: "Content-Length") != nil {
                throw NativeMCPError.responseTooLarge
            }
            if http.statusCode == 202 { return }
            try await handleUnspecifiedLength(bytes: bytes, response: http,
                                               expectedID: expectedID, initialize: isInitialize)
            return
        }
        if http.statusCode == 202 { return }
        try await handleUnspecifiedLength(bytes: bytes, response: http,
                                           expectedID: expectedID, initialize: isInitialize)
    }

    private func handleUnspecifiedLength(bytes: URLSession.AsyncBytes, response: HTTPURLResponse,
                                         expectedID: String?, initialize: Bool) async throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard contentType == "application/json" || contentType == "text/event-stream" else {
            throw NativeMCPError.invalidResponse
        }
        let newID = response.value(forHTTPHeaderField: "MCP-Session-Id")
        if let newID {
            guard !newID.isEmpty, newID.utf8.count <= 128,
                  !newID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw NativeMCPError.invalidSession }
            if let sessionID {
                guard sessionID == newID else { throw NativeMCPError.invalidSession }
            } else if !initialize {
                throw NativeMCPError.invalidSession
            }
        }
        var total = 0
        var payload = Data()
        var eventName = ""
        var eventData: [String] = []
        var gotResponse = false
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= Self.maximumResponseBytes else { throw NativeMCPError.responseTooLarge }
            payload.append(byte)
            if contentType == "text/event-stream", byte == 10 {
                if payload.last == 10 { payload.removeLast() }
                if payload.last == 13 { payload.removeLast() }
                guard let line = String(data: payload, encoding: .utf8) else {
                    throw NativeMCPError.invalidResponse
                }
                payload.removeAll(keepingCapacity: true)
                if line.isEmpty {
                    if !eventData.isEmpty, eventName.isEmpty || eventName == "message" {
                        let message = Data(eventData.joined(separator: "\n").utf8)
                        let matches = try inspect(message, expectedID: expectedID,
                                                  initialize: initialize)
                        if initialize && matches { sessionID = newID; negotiatedVersion = "2025-11-25" }
                        continuation.yield(message)
                        if matches { gotResponse = true; break }
                    }
                    eventData = []
                    eventName = ""
                } else if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    eventData.append(value)
                } else if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard isConnected else { throw NativeMCPError.missingConnection }
        if contentType == "application/json" {
            guard !payload.isEmpty else { throw NativeMCPError.invalidResponse }
            let matches = try inspect(payload, expectedID: expectedID, initialize: initialize)
            if initialize && matches { sessionID = newID; negotiatedVersion = "2025-11-25" }
            continuation.yield(payload)
            gotResponse = matches
        }
        guard expectedID == nil || gotResponse else { throw NativeMCPError.invalidResponse }
    }

    /// Wire-level validation only; MCP.Client still decodes typed JSON-RPC messages.
    /// Reject version mismatch BEFORE Client can send notifications/initialized.
    private func inspect(_ message: Data, expectedID: String?, initialize: Bool) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { throw NativeMCPError.invalidResponse }
        if let expectedID, object["id"] as? String == expectedID {
            guard object["result"] != nil || object["error"] != nil else {
                throw NativeMCPError.invalidResponse
            }
            if initialize, let result = object["result"] as? [String: Any] {
                guard result["protocolVersion"] as? String == "2025-11-25" else {
                    throw NativeMCPError.unsupportedVersion
                }
                guard (result["capabilities"] as? [String: Any])?["tools"] is [String: Any] else {
                    throw NativeMCPError.invalidResponse
                }
            }
            return true
        }
        // Permit server notifications within POST SSE only; no server-originated
        // request or unrelated response can satisfy another request ID.
        guard object["id"] == nil, object["method"] is String else {
            throw NativeMCPError.invalidResponse
        }
        return false
    }
}
