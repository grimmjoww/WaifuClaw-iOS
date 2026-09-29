import Foundation

/// Empty body / empty response helpers for endpoints without payloads.
struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}

/// Single SSE frame from the chat stream.
struct SSEEvent {
    let event: String
    let data: String
}

/// HTTP client for the WaifuClaw gateway.
///
/// - Auth: `Authorization: Bearer <device-token>` (ARCHITECTURE.md §1.2).
///   The token lives in the Keychain and is NEVER logged.
/// - Every 401 is inspected: a revoked device surfaces as `.deviceRevoked`
///   (audit §2), never a generic failure.
@MainActor
final class APIClient: ObservableObject {
    var baseURL: URL
    var connectionKind: () -> ConnectionKind = { .lan }
    var onDeviceRevoked: (() -> Void)?

    private let session: URLSession
    private let pinningDelegate: TLSPinningDelegate

    init(
        baseURL: URL,
        connectionKind: @escaping () -> ConnectionKind = { .lan },
        onMismatch: @escaping (_ expected: String, _ actual: String) -> Void,
        onDeviceRevoked: (() -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.connectionKind = connectionKind
        self.onDeviceRevoked = onDeviceRevoked
        let delegate = TLSPinningDelegate(
            expectedFingerprint: { KeychainStore.pinnedFingerprint },
            onMismatch: onMismatch
        )
        self.pinningDelegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Request builders

    private func authedRequest<B: Encodable>(path: String, method: String, body: B?) throws -> URLRequest {
        guard let token = KeychainStore.deviceToken else { throw APIError.notPaired }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WaifuClaw-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    // MARK: - Typed calls

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try authedRequest(path: path, method: "GET", body: Optional<EmptyBody>.none))
    }

    func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await perform(try authedRequest(path: path, method: "POST", body: body))
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try authedRequest(path: path, method: "POST", body: Optional<EmptyBody>.none))
    }

    func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await perform(try authedRequest(path: path, method: "PATCH", body: body))
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try authedRequest(path: path, method: "DELETE", body: Optional<EmptyBody>.none))
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapRequestError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            if data.isEmpty, T.self == EmptyResponse.self {
                // swiftlint:disable:next force_cast
                return EmptyResponse() as! T
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decoding
            }
        case 401:
            if isRevoked(data) {
                onDeviceRevoked?()
                throw APIError.deviceRevoked
            }
            throw APIError.http(status: 401, message: message(from: data) ?? "Your session expired — pair again.")
        case 402:
            throw APIError.paymentRequired
        case 409:
            // Contract §4: the desktop rejects a dead BYOK key mid-run with
            // {"code": "byok_key_invalid", "provider": "<id>"}.
            if let provider = byokKeyInvalidProvider(from: data) {
                throw APIError.byokKeyInvalid(provider: provider)
            }
            throw APIError.http(status: 409, message: message(from: data))
        case 410:
            throw APIError.pairingCodeExpired
        default:
            throw APIError.http(status: http.statusCode, message: message(from: data))
        }
    }

    // MARK: - Chat SSE stream

    /// Streams `POST /api/remote/v1/chat/stream` on the CALLER's task, so
    /// cancelling the caller (Stop button, view dismissal) promptly cancels
    /// the connection. `onHeaders` fires once with the response headers
    /// (`Content-Location` carries the run id); `onEvent` fires per SSE frame
    /// on the caller's executor. Throws `APIError`.
    func streamChat(
        _ body: ChatStreamRequest,
        onHeaders: @escaping ([AnyHashable: Any]) -> Void,
        onEvent: @escaping (SSEEvent) throws -> Void
    ) async throws {
        var request = try authedRequest(path: Endpoints.Remote.chatStream, method: "POST", body: body)
        request.timeoutInterval = 300
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapRequestError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        onHeaders(http.allHeaderFields)
        guard 200..<300 ~= http.statusCode else {
            throw streamStatusError(http.statusCode)
        }
        var event = "message"
        var dataLines: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(
                    String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                )
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !dataLines.isEmpty {
                    let payload = dataLines.joined(separator: "\n")
                    dataLines = []
                    if payload == "[DONE]" { return }
                    try onEvent(SSEEvent(event: event, data: payload))
                    event = "message"
                }
            }
            // Lines starting with ":" are SSE comments/heartbeats — ignored.
        }
    }

    private func streamStatusError(_ status: Int) -> APIError {
        switch status {
        case 401:
            // The non-streaming wake poll is the authoritative revoked detector;
            // the view model triggers a refresh on any 401.
            return APIError.http(status: 401, message: "Your session expired — pair again.")
        case 402: return .paymentRequired
        case 409:
            // SSE headers carry no body, so the provider id isn't available —
            // "provider" keeps the message grammatical (see errorDescription).
            return .byokKeyInvalid(provider: "provider")
        default: return .http(status: status, message: nil)
        }
    }

    // MARK: - Error mapping

    /// Maps transport errors, giving TLS pin failures priority: a pinning
    /// cancel surfaces as the security error, not a generic network error.
    private func mapRequestError(_ error: Error) -> APIError {
        if let pin = pinningDelegate.pinFailure {
            pinningDelegate.clearPinFailure()
            return .tlsMismatch(expected: pin.expected, actual: pin.actual)
        }
        if let urlError = error as? URLError {
            return mapURLError(urlError)
        }
        return .network(URLError(.unknown))
    }

    private func mapURLError(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .timedOut, .networkConnectionLost, .dnsLookupFailed:
            return .unreachable(kind: connectionKind())
        default:
            // A connection that establishes but gets no valid HTTP response
            // usually means the desktop app itself isn't running.
            return .desktopNotResponding
        }
    }

    private func isRevoked(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let candidates = [json["code"], json["detail"], json["error"], json["message"]]
            .compactMap { $0 as? String }
        return candidates.contains { $0.lowercased().contains("revok") }
    }

    private func message(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["detail"] as? String)
            ?? (json["message"] as? String)
            ?? (json["error"] as? String)
    }

    /// Mirrors `isRevoked`: returns the provider id when the body carries the
    /// contract's machine-readable BYOK rejection, nil otherwise.
    private func byokKeyInvalidProvider(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? String) == "byok_key_invalid"
        else { return nil }
        return (json["provider"] as? String) ?? "provider"
    }
}
