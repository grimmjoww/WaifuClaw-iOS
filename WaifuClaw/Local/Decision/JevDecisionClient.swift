import Foundation

/// A typed, informational Jev result. It is deliberately not an authorization
/// object: callers must continue to enforce all workspace, write, execution,
/// and Git safety rules themselves.
struct JevAssessment: Sendable, Equatable {
    let model: String
    let intent: JevIntentAssessment
    let needsWrite: JevNoulAssessment
    let usage: JevUsage
}

enum JevIntent: String, Sendable, Equatable {
    case inspect
    case general
}

struct JevIntentAssessment: Sendable, Equatable {
    let choice: JevIntent
    let probabilities: JevIntentProbabilities
    let confidence: Double
}

struct JevIntentProbabilities: Sendable, Equatable {
    let inspect: Double
    let general: Double
}

/// A Noul is the probability that the stated condition is true. TypeSafe does
/// not return a separate confidence value for Noul answers.
struct JevNoulAssessment: Sendable, Equatable {
    let probability: Double
}

struct JevUsage: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
}

enum JevDecisionError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidAPIKey
    case unauthorized
    case requestRejected
    case rateLimited
    case overloaded
    case redirectBlocked
    case invalidContentType
    case invalidResponse
    case unexpectedHTTPStatus(Int)
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Enter a request of 1 to 4,000 characters before asking Jev."
        case .invalidAPIKey:
            "Enter a valid Jev API key."
        case .unauthorized:
            "TypeSafe did not accept this Jev API key."
        case .requestRejected:
            "TypeSafe rejected the Jev request format."
        case .rateLimited:
            "TypeSafe rate-limited the Jev request. Try again shortly."
        case .overloaded:
            "TypeSafe is temporarily overloaded. Try again shortly."
        case .redirectBlocked:
            "The Jev request was redirected and was blocked to protect your key."
        case .invalidContentType, .invalidResponse:
            "TypeSafe returned a Jev response that did not match the expected typed schema."
        case .unexpectedHTTPStatus(let status):
            "TypeSafe returned an unexpected Jev status (\(status))."
        case .transportFailure:
            "The Jev request could not reach TypeSafe. Check your connection and try again."
        }
    }
}

/// Minimal HTTP client for the fixed TypeSafe System One endpoint.
///
/// The only user-derived state submitted is `request` and the boolean workspace
/// flag. In particular, this client has no parameter for workspace paths or
/// project content, so it cannot send project files to Jev by accident.
struct JevDecisionClient {
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let maxRetries = 2
    private static let maximumBackoff: TimeInterval = 8

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    /// Makes one typed Jev assessment. A 429 or 529 receives at most two
    /// cancellation-aware exponential-backoff retries; no other error retries.
    func assess(
        request: String,
        workspaceSelected: Bool,
        apiKey: String
    ) async throws -> JevAssessment {
        let urlRequest = try Self.makeURLRequest(
            request: request,
            workspaceSelected: workspaceSelected,
            apiKey: apiKey
        )

        var retriesPerformed = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await send(urlRequest)
            let status = response.statusCode

            if (300 ... 399).contains(status) {
                // A task-specific delegate also declines redirects. This makes
                // a direct 3xx response explicit if URLSession returns it.
                throw JevDecisionError.redirectBlocked
            }

            switch status {
            case 200 ... 299:
                guard response.mimeType?.lowercased() == "application/json" else {
                    throw JevDecisionError.invalidContentType
                }
                return try Self.decodeAssessment(from: data)

            case 401:
                throw JevDecisionError.unauthorized

            case 422:
                throw JevDecisionError.requestRejected

            case 429, 529:
                guard retriesPerformed < Self.maxRetries else {
                    throw status == 429
                        ? JevDecisionError.rateLimited
                        : JevDecisionError.overloaded
                }
                let delay = Self.retryDelay(response: response, retryIndex: retriesPerformed)
                retriesPerformed += 1
                try await Task.sleep(for: .seconds(delay))

            default:
                throw JevDecisionError.unexpectedHTTPStatus(status)
            }
        }
    }

    /// Internal for unit tests. It intentionally has no base-URL argument: all
    /// production requests use the fixed HTTPS TypeSafe endpoint.
    static func makeURLRequest(
        request: String,
        workspaceSelected: Bool,
        apiKey: String
    ) throws -> URLRequest {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty, trimmedRequest.count <= 4_000 else {
            throw JevDecisionError.invalidRequest
        }

        let sanitizedKey = try validatedAPIKey(apiKey)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(sanitizedKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestPayload(request: trimmedRequest, workspaceSelected: workspaceSelected)
        )
        return urlRequest
    }

    /// Internal for schema-only tests. It validates every value relied upon by
    /// the app and never retains or logs the untrusted response body.
    static func decodeAssessment(from data: Data) throws -> JevAssessment {
        let decoded: ResponsePayload
        do {
            decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
        } catch {
            throw JevDecisionError.invalidResponse
        }

        let model = decoded.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200 else {
            throw JevDecisionError.invalidResponse
        }
        guard decoded.answers.intent.type == "choice",
              decoded.answers.needsWrite.type == "noul",
              let intent = JevIntent(rawValue: decoded.answers.intent.choice),
              decoded.usage.inputTokens >= 0,
              decoded.usage.outputTokens >= 0
        else {
            throw JevDecisionError.invalidResponse
        }

        let probabilities = decoded.answers.intent.probabilities
        guard Set(probabilities.keys) == Set([JevIntent.inspect.rawValue, JevIntent.general.rawValue]),
              let inspect = probabilities[JevIntent.inspect.rawValue],
              let general = probabilities[JevIntent.general.rawValue],
              isProbability(inspect),
              isProbability(general),
              isProbability(decoded.answers.intent.confidence),
              isProbability(decoded.answers.needsWrite.noul),
              abs((inspect + general) - 1) <= 0.001
        else {
            throw JevDecisionError.invalidResponse
        }

        // The API documents `choice` as the highest-probability option. Accept
        // a tie (within floating-point tolerance), but reject contradictions.
        let selectedProbability = intent == .inspect ? inspect : general
        let otherProbability = intent == .inspect ? general : inspect
        guard selectedProbability + 0.000_001 >= otherProbability else {
            throw JevDecisionError.invalidResponse
        }

        return JevAssessment(
            model: model,
            intent: JevIntentAssessment(
                choice: intent,
                probabilities: JevIntentProbabilities(inspect: inspect, general: general),
                confidence: decoded.answers.intent.confidence
            ),
            needsWrite: JevNoulAssessment(probability: decoded.answers.needsWrite.noul),
            usage: JevUsage(
                inputTokens: decoded.usage.inputTokens,
                outputTokens: decoded.usage.outputTokens
            )
        )
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let redirectBlocker = NoRedirectDelegate()
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectBlocker)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JevDecisionError.transportFailure
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled, Task.isCancelled {
            throw CancellationError()
        } catch {
            if redirectBlocker.didBlockRedirect {
                throw JevDecisionError.redirectBlocked
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            // Do not surface URLSession's description: it may contain server
            // data and is not useful to the user for this fixed endpoint.
            throw JevDecisionError.transportFailure
        }
    }

    private static func validatedAPIKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.count <= 4_096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw JevDecisionError.invalidAPIKey
        }
        return key
    }

    private static func isProbability(_ value: Double) -> Bool {
        value.isFinite && (0 ... 1).contains(value)
    }

    private static func retryDelay(response: HTTPURLResponse, retryIndex: Int) -> TimeInterval {
        let exponential = min(
            maximumBackoff,
            0.5 * pow(2, Double(retryIndex))
        )
        guard let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
              let serverDelay = TimeInterval(retryAfter),
              serverDelay.isFinite,
              serverDelay >= 0
        else {
            return exponential
        }
        // Keep provider-directed retries bounded as well as retry count.
        return min(maximumBackoff, max(0.25, serverDelay))
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var blocked = false

    var didBlockRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        blocked = true
        lock.unlock()
        // Never follow a redirect with the Bearer token attached.
        completionHandler(nil)
    }
}

private struct RequestPayload: Encodable {
    let state: State
    let model = "jev-latest"
    let questions = Questions()

    init(request: String, workspaceSelected: Bool) {
        state = State(request: request, workspaceSelected: workspaceSelected)
    }

    struct State: Encodable {
        let request: String
        let workspaceSelected: Bool

        enum CodingKeys: String, CodingKey {
            case request
            case workspaceSelected = "workspace_selected"
        }
    }

    struct Questions: Encodable {
        let intent = IntentQuestion()
        let needsWrite = NeedsWriteQuestion()

        enum CodingKeys: String, CodingKey {
            case intent
            case needsWrite = "needs_write"
        }
    }

    struct IntentQuestion: Encodable {
        let type = "choice"
        let instructions = "Is the request to inspect project files or answer without project access?"
        let criteria = Criteria()

        struct Criteria: Encodable {
            let inspect = "Needs read-only project inspection"
            let general = "Can respond without project inspection"
        }
    }

    struct NeedsWriteQuestion: Encodable {
        let type = "noul"
        let instructions = "Does this request ask for writing files, executing code, or git operations unavailable to the current read-only agent?"
    }
}

private struct ResponsePayload: Decodable {
    let model: String
    let answers: Answers
    let usage: Usage

    struct Answers: Decodable {
        let intent: ChoiceAnswer
        let needsWrite: NoulAnswer

        enum CodingKeys: String, CodingKey {
            case intent
            case needsWrite = "needs_write"
        }
    }

    struct ChoiceAnswer: Decodable {
        let type: String
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct NoulAnswer: Decodable {
        let type: String
        let noul: Double
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}
