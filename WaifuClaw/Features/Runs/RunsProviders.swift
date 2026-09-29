import Foundation

// MARK: - Runs data contract (leaf 1.3.1)
//
// Views (leaf 1.3.3) depend ONLY on `RunsData` — never on APIClient.
// Two implementations ship:
//   - `MockRunsData`  previews / offline development (see MockRunsData.swift),
//                       with loud-failure modes
//   - `LiveRunsData`  real gateway endpoints, verified 2026-09-29 against
//                       backend/app/gateway/routers/thread_runs.py.
//
// Endpoint honesty (G3): every live method cites the exact backend route.
// Three run routes exist in the backend but have NO constant in
// Core/API/Endpoints.swift yet (another leaf's file — not touched here):
//   GET /api/threads/{thread_id}/runs
//   GET /api/threads/{thread_id}/runs/{run_id}
//   GET /api/threads/{thread_id}/runs/{run_id}/events
// They are called by literal path with the route cited in comments. This is
// NOT an invented contract — the routes were read verbatim from
// thread_runs.py (lines 571, 581, 867).

// MARK: - Errors

/// User-facing run errors. Every case has a message a human can act on.
enum RunsError: LocalizedError, Equatable {
    case notPaired
    case offline
    case sessionExpired
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "No computer paired — pair your desktop to load runs."
        case .offline:
            "Can't reach your computer — check it's awake and on the same network."
        case .sessionExpired:
            "Your session expired — pair again to reconnect."
        case .server(let message):
            message
        }
    }

    /// Maps transport errors to run errors. `CancellationError` is never
    /// mapped here — callers filter it first, because a cancelled load is a
    /// normal lifecycle event, not a failure (bug-patterns.md).
    static func describe(_ error: Error) -> RunsError {
        guard let api = error as? APIError else {
            return .server(message: error.localizedDescription)
        }
        switch api {
        case .notPaired:
            .notPaired
        case .deviceRevoked:
            .sessionExpired
        case .unreachable, .desktopNotResponding, .network:
            .offline
        case .tlsMismatch:
            .server(message: "Security warning: your computer's identity changed.")
        case .http(let status, let message):
            if status == 401 {
                .sessionExpired
            } else if status == 404 {
                .server(message: "That run no longer exists on your computer.")
            } else {
                .server(message: message ?? "The desktop returned an error (HTTP \(status)).")
            }
        case .paymentRequired:
            .server(message: "This needs a Pro license — see Settings → Pro.")
        case .pairingCodeExpired, .decoding:
            .server(message: api.errorDescription ?? "Something went wrong loading the run.")
        }
    }
}

// MARK: - Data source protocol

/// Run data. The async calls are independent so the view model can load
/// (and fail) the list and the detail on their own.
protocol RunsData {
    /// All runs the backend knows for one thread, newest first.
    func runs(forThread threadID: String) async throws -> [RunSummary]
    /// Recent runs across threads — bounded fan-out over threads/search.
    func recentRuns(limit: Int) async throws -> [RunSummary]
    /// Full detail for contract §5 (summary + steps + evidence).
    func runDetail(threadID: String, runID: String) async throws -> RunDetail
    /// Timeline steps alone, for lightweight refresh.
    func runSteps(threadID: String, runID: String) async throws -> [RunStep]
    /// Cancel a running/pending run. `rollback: true` reverts to the
    /// pre-run checkpoint; `false` just interrupts (keeps the checkpoint,
    /// resumable). Throws `.server` with the backend's 409 detail when the
    /// run can't be cancelled (already terminal).
    func cancelRun(threadID: String, runID: String, rollback: Bool) async throws
}

// MARK: - Live (real gateway endpoints)

/// GET /api/threads/{thread_id}/runs → [RunResponse]
/// (thread_runs.py:571). Only the fields the phone needs are decoded;
/// `objective` is read tolerantly from metadata/kwargs, which are
/// open-ended dicts.
private struct RunResponseDTO: Decodable {
    let run_id: String
    let thread_id: String
    let status: String
    let created_at: String?
    let updated_at: String?
    let message_count: Int?
    let total_tokens: Int?
    let objective: String?

    enum CodingKeys: String, CodingKey {
        case run_id, thread_id, status, created_at, updated_at
        case message_count, total_tokens, metadata, kwargs
    }

    enum MetaKeys: String, CodingKey {
        case objective, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run_id = try container.decode(String.self, forKey: .run_id)
        thread_id = try container.decode(String.self, forKey: .thread_id)
        status = try container.decode(String.self, forKey: .status)
        created_at = try container.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try container.decodeIfPresent(String.self, forKey: .updated_at)
        message_count = try container.decodeIfPresent(Int.self, forKey: .message_count)
        total_tokens = try container.decodeIfPresent(Int.self, forKey: .total_tokens)
        // Objective may live in metadata or kwargs — read both, prefer metadata.
        var found: String?
        for key in [CodingKeys.metadata, CodingKeys.kwargs] {
            if let meta = try? container.nestedContainer(keyedBy: MetaKeys.self, forKey: key) {
                found = (try? meta.decodeIfPresent(String.self, forKey: .objective))
                    ?? (try? meta.decodeIfPresent(String.self, forKey: .title))
                if found != nil { break }
            }
        }
        objective = found
    }
}

/// GET /api/threads/{thread_id}/runs/{run_id}/events → [dict]
/// (thread_runs.py:867). The event schema is open-ended (debug/audit), so
/// only a few likely keys are read and everything else is ignored.
private struct RunEventDTO: Decodable {
    let type: String?
    let name: String?
    let step: String?
    let at: String?

    enum CodingKeys: String, CodingKey {
        case type, name, step
        case timestamp, ts, created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        step = try container.decodeIfPresent(String.self, forKey: .step)
        at = (try? container.decodeIfPresent(String.self, forKey: .timestamp))
            ?? (try? container.decodeIfPresent(String.self, forKey: .ts))
            ?? (try? container.decodeIfPresent(String.self, forKey: .created_at))
    }
}

/// POST /api/threads/search item, trimmed to what recentRuns needs.
private struct ThreadLiteDTO: Decodable {
    let thread_id: String
    let updated_at: String?
}

private let runsISOFormatter = ISO8601DateFormatter()

/// Real gateway data source.
struct LiveRunsData: RunsData {
    let api: APIClient

    // MARK: List

    /// GET /api/threads/{thread_id}/runs (thread_runs.py:571).
    func runs(forThread threadID: String) async throws -> [RunSummary] {
        let dtos: [RunResponseDTO] = try await api.get(Endpoints.Threads.runs(threadID))
        return dtos.map(Self.summary(from:)).sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    /// The backend has no global "recent runs" route, so this fans out over
    /// POST /api/threads/search (Endpoints.Threads.search) and takes the
    /// runs of the most recently touched threads. One thread failing does
    /// not kill the list (partial results); cancellation still propagates.
    func recentRuns(limit: Int) async throws -> [RunSummary] {
        var request = ThreadSearchRequest()
        request.limit = 8
        let threads: [ThreadLiteDTO] = try await api.post(Endpoints.Threads.search, body: request)
        var all: [RunSummary] = []
        for thread in threads.prefix(5) {
            do {
                all.append(contentsOf: try await runs(forThread: thread.thread_id))
            } catch is CancellationError {
                throw // A cancelled load is a lifecycle event, not a failure.
            } catch {
                // A single thread's failure is not the list's failure.
                continue
            }
        }
        let sorted = all.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return Array(sorted.prefix(limit))
    }

    // MARK: Detail

    /// GET /api/threads/{thread_id}/runs/{run_id} (thread_runs.py:581) plus
    /// the events endpoint for the timeline. Evidence, frozen candidate, and
    /// reviewers have no backend source — always empty/nil from live data
    /// (mock-only types, see RunModels.swift).
    func runDetail(threadID: String, runID: String) async throws -> RunDetail {
        let dto: RunResponseDTO = try await api.get(Endpoints.Threads.run(threadID, runID))
        let summary = Self.summary(from: dto)
        let steps = try await runSteps(threadID: threadID, runID: runID)
        return RunDetail(
            summary: summary,
            steps: steps,
            evidence: [],
            frozenCandidate: nil,
            riskBullets: [],
            reviewers: []
        )
    }

    /// GET /api/threads/{thread_id}/runs/{run_id}/events (thread_runs.py:867).
    /// Step-like events become timeline steps; when the backend emits none
    /// recognizable, the timeline falls back to a single status-derived step
    /// rather than rendering nothing.
    func runSteps(threadID: String, runID: String) async throws -> [RunStep] {
        let events: [RunEventDTO] = try await api.get(
            Endpoints.Threads.runEvents(threadID, runID) + "?limit=500"
        )
        let stepEvents = events.enumerated().compactMap { index, event -> RunStep? in
            let label = event.step ?? event.name
            let kind = (event.type ?? "").lowercased()
            guard label != nil || kind.contains("step") else { return nil }
            let state: RunStep.State
            if kind.contains("fail") || kind.contains("error") {
                state = .failed
            } else if kind.contains("complete") || kind.contains("done") || kind.contains("success") {
                state = .done
            } else if kind.contains("start") || kind.contains("run") {
                state = .active
            } else {
                state = .pending
            }
            return RunStep(
                id: "\(runID)-\(index)",
                index: index,
                name: label ?? "Step \(index + 1)",
                state: state,
                startedAt: event.at.flatMap { runsISOFormatter.date(from: $0) },
                endedAt: nil
            )
        }
        if !stepEvents.isEmpty { return stepEvents }
        // Fallback: one synthetic step reflecting the run's status.
        let dto: RunResponseDTO = try await api.get(Endpoints.Threads.run(threadID, runID))
        let status = RunStatus(raw: dto.status)
        let state: RunStep.State
        switch status {
        case .success: state = .done
        case .error, .timeout: state = .failed
        case .running: state = .active
        case .pending, .interrupted, .unknown: state = .pending
        }
        return [RunStep(
            id: "\(runID)-0",
            index: 0,
            name: "Run",
            state: state,
            startedAt: dto.created_at.flatMap { runsISOFormatter.date(from: $0) },
            endedAt: nil
        )]
    }

    // MARK: Cancel / rollback

    /// POST /api/threads/{thread_id}/runs/{run_id}/cancel?action=…&wait=true
    /// (thread_runs.py:593, via Endpoints.Threads.cancelRun).
    /// - action=rollback: stop execution AND revert to the pre-run
    ///   checkpoint — this is the real backing for contract §5's
    ///   "Rollback to stable" sticky button. Note the semantics: it rolls
    ///   back *this run's* changes, not the app to a "stable version".
    /// - action=interrupt: stop execution, keep the checkpoint (resumable).
    /// `wait=true` blocks until the run fully stops; the endpoint answers
    /// 204 (empty body) — decoded as EmptyResponse.
    func cancelRun(threadID: String, runID: String, rollback: Bool) async throws {
        let action = rollback ? "rollback" : "interrupt"
        let path = Endpoints.Threads.cancelRun(threadID, runID) + "?action=\(action)&wait=true"
        let _: EmptyResponse = try await api.post(path)
    }

    // MARK: Mapping

    private static func summary(from dto: RunResponseDTO) -> RunSummary {
        let status = RunStatus(raw: dto.status)
        return RunSummary(
            id: dto.run_id,
            threadID: dto.thread_id,
            objective: dto.objective ?? "",
            status: status,
            riskTier: nil, // No backend source (mock-only type).
            progress: nil, // No backend source; the timeline shows steps instead.
            stepIndex: nil,
            stepTotal: nil,
            currentStepName: nil,
            model: nil, // kwargs may carry it, but the key is not contractual — not read.
            startedAt: dto.created_at.flatMap { runsISOFormatter.date(from: $0) },
            updatedAt: dto.updated_at.flatMap { runsISOFormatter.date(from: $0) },
            messageCount: dto.message_count ?? 0,
            totalTokens: dto.total_tokens ?? 0
        )
    }
}
