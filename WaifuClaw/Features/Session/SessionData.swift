import Foundation

// MARK: - SessionData protocol

/// Read-only session data: the event backlog, the skill receipts, and the
/// live event stream for one run. Implemented live against the gateway;
/// previews use `MockSessionData`.
protocol SessionData {
    /// Stored events for a run, oldest first.
    /// GET /api/threads/{thread_id}/runs/{run_id}/events (thread_runs.py:867).
    func sessionEvents(threadID: String, runID: String) async throws -> [SessionEvent]
    /// Skill lifecycle projection for a run.
    /// GET /api/threads/{thread_id}/runs/{run_id}/skill-receipts (thread_runs.py:882).
    func skillReceipts(threadID: String, runID: String) async throws -> SkillReceiptList
    /// Live SSE frames for a run.
    /// GET /api/threads/{thread_id}/runs/{run_id}/join (thread_runs.py:677).
    /// Throws `SessionStreamError.runNotActive` (HTTP 409) when the run is
    /// not active on the paired worker — the caller shows the backlog as
    /// "Ended" instead of failing loudly.
    func sessionEventStream(threadID: String, runID: String) -> AsyncThrowingStream<SessionEvent, Error>
}

/// The join stream ended for a reason the UI handles without an error card.
enum SessionStreamError: Error, Equatable {
    /// HTTP 409: run is not active on this worker and cannot be streamed.
    case runNotActive
}

// MARK: - Tolerant JSON

/// Best-effort JSON value for the open-ended event payloads the backend
/// stores (message dumps, tool results, skill lifecycle content).
private enum SessionJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SessionJSON])
    case object([String: SessionJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode([SessionJSON].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: SessionJSON].self) {
            self = .object(value)
            return
        }
        throw DecodingError.typeMismatch(
            SessionJSON.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON value in session event payload"
            )
        )
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: SessionJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Human text from a message/tool dump: plain strings, LangChain message
    /// "content" fields, or content-block lists ([{"text": ...}]).
    var messageText: String? {
        switch self {
        case .string(let value):
            return value
        case .array(let values):
            let texts = values.compactMap { $0.objectValue?["text"]?.stringValue ?? $0.messageText }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        case .object(let dict):
            if let content = dict["content"] { return content.messageText }
            return dict["text"]?.stringValue
        default:
            return nil
        }
    }
}

// MARK: - DTOs

/// One stored run event (journal.py `_put`: event_type / category /
/// content / metadata / created_at). Decoded tolerantly — unknown shapes
/// degrade to a bare event_type line, never a decode failure.
private struct StoredEventDTO: Decodable {
    let event_type: String?
    let created_at: String?
    let content: SessionJSON?
    let metadata: [String: SessionJSON]?
}

private struct SkillReceiptEventDTO: Decodable {
    let state: String?
}

private struct SkillReceiptDTO: Decodable {
    let receipt_id: String
    let skill_id: String
    let skill_name: String
    let category: String
    let current_state: String?
    let requires_attention: Bool
    let events: [SkillReceiptEventDTO]
}

private struct SkillReceiptEnvelopeDTO: Decodable {
    let data: [SkillReceiptDTO]
    let telemetry_available: Bool
    let has_more: Bool
}

private let sessionISOFormatter = ISO8601DateFormatter()

// MARK: - SessionEvent construction

extension SessionEvent {
    fileprivate init(stored dto: StoredEventDTO, index: Int) {
        let kind = dto.event_type ?? "event"
        let occurredAt = dto.created_at.flatMap { sessionISOFormatter.date(from: $0) }
        let (summary, isError) = Self.summarizeStored(kind: kind, dto: dto)
        self.init(
            id: "stored-\(index)",
            occurredAt: occurredAt,
            kind: kind,
            summary: summary,
            isError: isError
        )
    }

    init(liveEvent name: String, data: String, index: Int) {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
        self.init(
            id: "live-\(index)",
            occurredAt: Date(),
            kind: name,
            summary: preview.isEmpty ? "[\(name)]" : "[\(name)] \(preview)",
            isError: false
        )
    }

    private static func summarizeStored(kind: String, dto: StoredEventDTO) -> (String, Bool) {
        let text = dto.content?.messageText?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "run.start":
            return ("▶ Run started", false)
        case "run.end":
            let status = dto.metadata?["status"]?.stringValue ?? "done"
            return ("■ Run ended (\(status))", false)
        case "run.error":
            return ("✖ " + truncate(text ?? "Run error", 300), true)
        case "llm.human.input":
            return (truncate(text ?? "Message", 300), false)
        case "llm.ai.response":
            return (truncate(text ?? "Response", 300), false)
        case "llm.tool.result":
            let name = dto.content?.objectValue?["name"]?.stringValue ?? "tool"
            let result = text.flatMap { $0.isEmpty ? nil : $0 } ?? "(no output)"
            return ("⚙ \(name): " + truncate(result, 200), false)
        case "llm.error":
            return ("✖ " + truncate(text ?? "Model error", 300), true)
        case "skill:lifecycle":
            return ("✦ " + truncate(text ?? "Skill event", 200), false)
        default:
            if kind.hasPrefix("middleware:") {
                return ("◈ " + truncate(text ?? kind, 200), false)
            }
            return (truncate(text ?? kind, 200), false)
        }
    }

    private static func truncate(_ value: String, _ limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

// MARK: - Live data source

/// Real gateway data source.
///
/// Live session data: run events, skill receipts, and the join SSE stream.
/// Route paths come from `Endpoints.Threads` (leaf-api-constants); only the
/// call-site query params (?limit=) stay local.
struct LiveSessionData: SessionData {
    let api: APIClient
    private let baseURL: URL
    private let connectionKind: ConnectionKind

    /// Reads @MainActor-isolated APIClient state up front so the SSE pump
    /// below can stay nonisolated.
    @MainActor init(api: APIClient) {
        self.api = api
        self.baseURL = api.baseURL
        self.connectionKind = api.connectionKind()
    }

    func sessionEvents(threadID: String, runID: String) async throws -> [SessionEvent] {
        let dtos: [StoredEventDTO] = try await api.get(
            Endpoints.Threads.runEvents(threadID, runID) + "?limit=500"
        )
        return dtos.enumerated().map { SessionEvent(stored: $1, index: $0) }
    }

    func skillReceipts(threadID: String, runID: String) async throws -> SkillReceiptList {
        let envelope: SkillReceiptEnvelopeDTO = try await api.get(
            Endpoints.Threads.skillReceipts(threadID, runID) + "?limit=100"
        )
        return SkillReceiptList(
            receipts: envelope.data.map {
                SkillReceipt(
                    id: $0.receipt_id,
                    skillName: $0.skill_name.isEmpty ? $0.skill_id : $0.skill_name,
                    category: $0.category,
                    state: $0.current_state,
                    requiresAttention: $0.requires_attention,
                    eventCount: $0.events.count
                )
            },
            telemetryAvailable: envelope.telemetry_available,
            hasMore: envelope.has_more
        )
    }

    func sessionEventStream(threadID: String, runID: String) -> AsyncThrowingStream<SessionEvent, Error> {
        let baseURL = self.baseURL
        let connectionKind = self.connectionKind
        return AsyncThrowingStream { continuation in
            let task = Task {
                await Self.pumpJoinStream(
                    threadID: threadID,
                    runID: runID,
                    baseURL: baseURL,
                    connectionKind: connectionKind,
                    continuation: continuation
                )
            }
            // Cancelling the consumer (pause / reconnect / view gone) must
            // cancel the pump — never leak a stream task.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: SSE pump (nonisolated — never blocks the main actor)

    /// Opens GET …/runs/{run}/join and yields one `SessionEvent` per SSE
    /// frame. Mirrors `APIClient.streamChat`'s frame parsing (event:/data:
    /// lines, blank-line dispatch, ":" heartbeats ignored, cancellation
    /// checked per line) with the chat-specific POST replaced by the join
    /// GET. TLS pinning mirrors APIClient's session setup.
    private static func pumpJoinStream(
        threadID: String,
        runID: String,
        baseURL: URL,
        connectionKind: ConnectionKind,
        continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    ) async {
        do {
            guard let token = KeychainStore.deviceToken else {
                continuation.finish(throwing: APIError.notPaired)
                return
            }
            var request = URLRequest(
                url: baseURL.appendingPathComponent(Endpoints.Threads.runJoin(threadID, runID))
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("WaifuClaw-iOS/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 300

            let pinningDelegate = TLSPinningDelegate(
                expectedFingerprint: { KeychainStore.pinnedFingerprint },
                onMismatch: { _, _ in }
            )
            let session = URLSession(
                configuration: .default,
                delegate: pinningDelegate,
                delegateQueue: nil
            )
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                throw mapStreamError(error, pinningDelegate: pinningDelegate, connectionKind: connectionKind)
            }
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network(URLError(.badServerResponse))
            }
            switch http.statusCode {
            case 200..<300:
                break
            case 401:
                throw APIError.http(status: 401, message: "Your session expired — pair again.")
            case 404:
                throw APIError.http(status: 404, message: "That run no longer exists on the desktop.")
            case 409:
                // Run is not active on this worker and cannot be streamed.
                throw SessionStreamError.runNotActive
            default:
                throw APIError.http(status: http.statusCode, message: nil)
            }

            var event = "message"
            var dataLines: [String] = []
            var index = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.hasPrefix("event:") {
                    event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(
                        String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                    )
                } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard !dataLines.isEmpty else { continue }
                    let payload = dataLines.joined(separator: "\n")
                    dataLines = []
                    let name = event
                    event = "message"
                    if payload == "[DONE]" || name == "end" {
                        continuation.finish()
                        return
                    }
                    index += 1
                    continuation.yield(SessionEvent(liveEvent: name, data: payload, index: index))
                }
                // Lines starting with ":" are SSE comments/heartbeats — ignored.
            }
            continuation.finish()
        } catch is CancellationError {
            // Pause / reconnect / view disappeared — normal lifecycle.
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Mirrors `APIClient.mapRequestError`: a pinning cancel surfaces as the
    /// security error, connectivity failures as `.unreachable`, anything
    /// else as "desktop not responding".
    private static func mapStreamError(
        _ error: Error,
        pinningDelegate: TLSPinningDelegate,
        connectionKind: ConnectionKind
    ) -> Error {
        if let pin = pinningDelegate.pinFailure {
            pinningDelegate.clearPinFailure()
            return APIError.tlsMismatch(expected: pin.expected, actual: pin.actual)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return APIError.unreachable(kind: connectionKind)
            default:
                return APIError.desktopNotResponding
            }
        }
        return APIError.network(URLError(.unknown))
    }
}

// MARK: - Mock data (previews only)

/// Preview-only session data. Never used in the real app — the Session UI
/// shows real backend events or honest empty/error states, never mock data.
struct MockSessionData: SessionData {
    enum Mode {
        case loaded
        case empty
        case error
    }

    let mode: Mode

    init(mode: Mode = .loaded) {
        self.mode = mode
    }

    func sessionEvents(threadID: String, runID: String) async throws -> [SessionEvent] {
        switch mode {
        case .loaded:
            return [
                SessionEvent(id: "s0", occurredAt: Date(), kind: "run.start", summary: "▶ Run started", isError: false),
                SessionEvent(id: "s1", occurredAt: Date(), kind: "llm.tool.result", summary: "⚙ shell: installed dependencies", isError: false),
                SessionEvent(id: "s2", occurredAt: Date(), kind: "llm.ai.response", summary: "Dependencies are in — wiring up the plan next.", isError: false),
            ]
        case .empty:
            return []
        case .error:
            throw APIError.http(status: 500, message: "Preview error")
        }
    }

    func skillReceipts(threadID: String, runID: String) async throws -> SkillReceiptList {
        switch mode {
        case .loaded:
            return SkillReceiptList(
                receipts: [
                    SkillReceipt(id: "r1", skillName: "web-search", category: "research", state: "active", requiresAttention: false, eventCount: 4),
                    SkillReceipt(id: "r2", skillName: "shell", category: "execution", state: "completed", requiresAttention: false, eventCount: 9),
                ],
                telemetryAvailable: true,
                hasMore: false
            )
        case .empty:
            return SkillReceiptList(receipts: [], telemetryAvailable: true, hasMore: false)
        case .error:
            throw APIError.http(status: 500, message: "Preview error")
        }
    }

    func sessionEventStream(threadID: String, runID: String) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
