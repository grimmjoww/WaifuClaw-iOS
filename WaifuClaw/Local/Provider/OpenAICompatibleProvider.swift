import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// OpenAI Chat Completions adapter for a user-owned API key.
///
/// The default endpoint is OpenAI's public `/v1` API. A custom endpoint is
/// accepted only after structural HTTPS checks and a public DNS resolution
/// check; local, loopback, and private-network endpoints are intentionally not
/// supported by this first adapter.
final class OpenAICompatibleProvider: AgentModelProvider, @unchecked Sendable {
    struct Configuration: Sendable {
        let model: String
        let baseURL: URL
        let apiKey: String

        init(model: String, baseURL: URL, apiKey: String) {
            self.model = model
            self.baseURL = baseURL
            self.apiKey = apiKey
        }

        /// The public OpenAI API base path expected by Chat Completions.
        static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    }

    private let configuration: Configuration
    private let validatedHost: String
    private let sessionConfiguration: URLSessionConfiguration

    init(configuration: Configuration, session: URLSession = .shared) throws {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AgentProviderError.emptyModel }
        guard !apiKey.isEmpty else { throw AgentProviderError.emptyAPIKey }

        validatedHost = try ProviderEndpointValidator.validateStructure(configuration.baseURL)
        self.configuration = Configuration(model: model, baseURL: configuration.baseURL, apiKey: apiKey)
        // A fresh session is made per stream so its delegate can reject every
        // redirect. Copying the supplied configuration retains test protocol
        // classes and caller transport settings without using its unsafe
        // redirect behavior directly.
        sessionConfiguration = session.configuration.copy() as! URLSessionConfiguration
    }

    convenience init(model: String, baseURL: URL, apiKey: String) throws {
        try self.init(configuration: Configuration(model: model, baseURL: baseURL, apiKey: apiKey))
    }

    convenience init(
        baseURL: URL,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) throws {
        try self.init(
            configuration: Configuration(model: model, baseURL: baseURL, apiKey: apiKey),
            session: session
        )
    }

    /// Streams the first OpenAI Chat Completions choice as text and completed
    /// function calls. This type never invokes a returned function call.
    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task { [self] in
                do {
                    try await run(messages: messages, tools: tools, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Cancelling the consumer cancels the Task awaiting
            // URLSession.bytes(for:), which cancels its underlying data task.
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }

    private func run(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition],
        continuation: AsyncThrowingStream<AgentProviderEvent, Error>.Continuation
    ) async throws {
        do {
            // DNS can block, so do this safety check on a utility executor,
            // never on a SwiftUI caller's executor.
            try await validatePublicResolution()
            try Task.checkCancellation()

            let request = try makeRequest(messages: messages, tools: tools)
            let redirectDelegate = RedirectRejectingSessionDelegate()
            let session = URLSession(
                configuration: securedSessionConfiguration(),
                delegate: redirectDelegate,
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                if redirectDelegate.didRejectRedirect {
                    throw AgentProviderError.redirected
                }
                if error is CancellationError {
                    throw CancellationError()
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw CancellationError()
                }
                throw AgentProviderError.network
            }

            try Task.checkCancellation()
            if redirectDelegate.didRejectRedirect {
                throw AgentProviderError.redirected
            }
            guard let http = response as? HTTPURLResponse else {
                throw AgentProviderError.malformedStream
            }
            guard (200..<300).contains(http.statusCode) else {
                // Deliberately do not read or expose the response body: provider
                // payloads can contain sensitive request-context information.
                throw AgentProviderError.httpStatus(http.statusCode)
            }

            var parser = OpenAICompatibleSSEParser()
            do {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    for event in try parser.consume(line: line) {
                        continuation.yield(event)
                    }
                }
                for event in try parser.finishInput() {
                    continuation.yield(event)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AgentProviderError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw AgentProviderError.network
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentProviderError {
            throw error
        } catch {
            // Preserve a deliberately small error surface: no key, request,
            // response, hostname, or provider payload can escape from here.
            throw AgentProviderError.network
        }
    }

    private func validatePublicResolution() async throws {
        let host = validatedHost
        try await Task.detached(priority: .utility) {
            try ProviderEndpointValidator.validateResolvedHost(host)
        }.value
    }

    private func makeRequest(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) throws -> URLRequest {
        var request = URLRequest(url: try chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try requestBody(messages: messages, tools: tools)
        return request
    }

    private func chatCompletionsURL() throws -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw AgentProviderError.invalidBaseURL
        }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasSuffix("/") { path += "/" }
        path += "chat/completions"
        components.percentEncodedPath = path
        guard let url = components.url else { throw AgentProviderError.invalidBaseURL }
        return url
    }

    private func requestBody(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) throws -> Data {
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": messages.map { message in
                var value: [String: Any] = [
                    "role": message.role,
                    "content": message.content
                ]
                if let toolCallID = message.toolCallID {
                    value["tool_call_id"] = toolCallID
                }
                if let toolCalls = message.toolCalls {
                    value["tool_calls"] = toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.argumentsJSON
                            ]
                        ]
                    }
                }
                return value
            }
        ]

        if !tools.isEmpty {
            body["tools"] = try tools.map { tool in
                guard !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parameters = try? JSONSerialization.jsonObject(with: tool.parametersJSON),
                      parameters is [String: Any]
                else {
                    throw AgentProviderError.invalidToolDefinition(name: tool.name)
                }
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters
                    ]
                ] as [String: Any]
            }
        }

        guard JSONSerialization.isValidJSONObject(body) else {
            throw AgentProviderError.requestEncoding
        }
        do {
            return try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw AgentProviderError.requestEncoding
        }
    }

    private func securedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return configuration
    }
}

/// Rejects all HTTP redirects rather than forwarding an Authorization header to
/// a different URL. The session is per stream, so redirect state is isolated.
private final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var rejectedRedirect = false

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        rejectedRedirect = true
        lock.unlock()
        completionHandler(nil)
    }
}

private enum ProviderEndpointValidator {
    static func validateStructure(_ url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw AgentProviderError.invalidBaseURL
        }
        guard scheme == "https" else { throw AgentProviderError.insecureBaseURL }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AgentProviderError.invalidBaseURL
        }

        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !normalizedHost.isEmpty,
              !isExplicitlyUnsafeHostName(normalizedHost),
              !isNumericAddress(normalizedHost)
        else {
            throw AgentProviderError.unsafeHost
        }
        return normalizedHost
    }

    /// Every address must be public. Rejecting mixed public/private DNS answers
    /// avoids accidentally accepting split-horizon or DNS-rebinding endpoints.
    static func validateResolvedHost(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw AgentProviderError.hostResolutionFailed
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var resolvedAddressCount = 0
        while let node = current {
            defer { current = node.pointee.ai_next }
            guard let address = node.pointee.ai_addr else { continue }
            switch Int32(node.pointee.ai_family) {
            case AF_INET:
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                guard isPublicIPv4(ipv4.sin_addr) else { throw AgentProviderError.unsafeHost }
                resolvedAddressCount += 1
            case AF_INET6:
                let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                guard isPublicIPv6(ipv6.sin6_addr) else { throw AgentProviderError.unsafeHost }
                resolvedAddressCount += 1
            default:
                continue
            }
        }

        guard resolvedAddressCount > 0 else {
            throw AgentProviderError.hostResolutionFailed
        }
    }

    private static func isExplicitlyUnsafeHostName(_ host: String) -> Bool {
        host == "localhost"
            || host == "localhost.localdomain"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa")
    }

    private static func isNumericAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private static func isPublicIPv4(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xFF)
        let second = UInt8((value >> 16) & 0xFF)
        let third = UInt8((value >> 8) & 0xFF)

        switch first {
        case 0, 10, 127, 224...255:
            return false
        case 100 where (64...127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16...31).contains(second):
            return false
        case 192 where second == 168:
            return false
        case 192 where second == 0 && third == 0:
            return false
        case 192 where second == 0 && third == 2:
            return false
        case 198 where second == 18 || second == 19:
            return false
        case 198 where second == 51 && third == 100:
            return false
        case 203 where second == 0 && third == 113:
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }

        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xFF && bytes[11] == 0xFF
        if isUnspecified || isLoopback || isIPv4Mapped { return false }

        // Unique-local (fc00::/7), link-local (fe80::/10), and multicast.
        if (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) {
            return false
        }
        return bytes[0] != 0xFF
    }
}
