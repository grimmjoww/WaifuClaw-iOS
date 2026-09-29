import Foundation

// MARK: - Dashboard data contract (leaf 1.2.1)
//
// Views (leaf 1.2.2) depend ONLY on `DashboardData` — never on APIClient.
// Three implementations ship:
//   - `MockDashboardData`      previews / offline development, with modes for
//                              every loud-failure state (G3)
//   - `LiveDashboardData`      real gateway endpoints (shapes verified against
//                              the backend routers, 2026-09-29 — see per-call
//                              comments). Nothing here is invented.
//   - `UnpairedDashboardData`  phone isn't paired: greeting still works
//                              (it's local); everything else throws
//                              `.notPaired` so views show the pairing prompt.

// MARK: - Snapshot models

/// Time-of-day greeting for the Home dashboard ("Good morning, Willie").
struct DashboardGreeting: Equatable {
    let salutation: String // "Good morning" | "Good afternoon" | "Good evening"
    let userName: String

    var text: String { "\(salutation), \(userName)" }

    static func current(userName: String, now: Date = Date.now) -> DashboardGreeting {
        let hour = Calendar.current.component(.hour, from: now)
        let salutation: String = switch hour {
        case 0..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        return DashboardGreeting(salutation: salutation, userName: userName)
    }
}

/// What the agent is doing right now, from GET /api/remote/v1/agent/status.
struct ActiveAgentInfo: Equatable {
    let isActive: Bool
    let activeRunCount: Int
    /// Model of the first active run, when the backend reports one.
    let currentModel: String?
    /// Thread id of the first active run — lets Home deep-link to it.
    let currentThreadID: String?

    var statusText: String {
        if isActive {
            "\(activeRunCount) run\(activeRunCount == 1 ? "" : "s") active"
        } else {
            "Idle"
        }
    }

    static let idle = ActiveAgentInfo(
        isActive: false, activeRunCount: 0, currentModel: nil, currentThreadID: nil
    )
}

/// One thread touched today, from POST /api/threads/search.
struct ThreadSummary: Identifiable, Equatable {
    let id: String // thread_id
    let title: String // backend `values.title`, may be empty
    /// Backend status: idle | busy | interrupted | error.
    let status: String
    let updatedAt: Date?

    var displayTitle: String {
        title.isEmpty ? "Thread \(id.prefix(8))" : title
    }
}

/// One memory category with its fact count, most common first.
struct MemoryCategoryCount: Equatable {
    let category: String
    let count: Int
}

/// Memory rollup for the dashboard, from GET /api/memory.
struct MemorySummary: Equatable {
    let factCount: Int
    /// Up to 3 categories with counts, most common first.
    let topCategories: [MemoryCategoryCount]
    /// Newest fact snippet, when any facts exist.
    let latestFact: String?

    static let empty = MemorySummary(factCount: 0, topCategories: [], latestFact: nil)
}

// MARK: - Load state (G3: failure is loud)

/// Per-section load state. Views switch on this — there is deliberately no
/// "empty screen" or endless spinner: `.failed` always carries a user-facing
/// message, and `.loaded([])` renders an explicit empty state.
enum LoadState<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(DashboardError)
}

/// User-facing dashboard errors. Every case has a message a human can act on.
enum DashboardError: LocalizedError, Equatable {
    case notPaired
    case offline
    case sessionExpired
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "No computer paired — pair your desktop to load the dashboard."
        case .offline:
            "Can't reach your computer — check it's awake and on the same network."
        case .sessionExpired:
            "Your session expired — pair again to reconnect."
        case .server(let message):
            message
        }
    }

    /// Maps transport errors to dashboard errors. `CancellationError` is never
    /// mapped here — callers filter it first, because a cancelled load is a
    /// normal lifecycle event, not a failure (bug-patterns.md).
    static func describe(_ error: Error) -> DashboardError {
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
            } else {
                .server(message: message ?? "The desktop returned an error (HTTP \(status)).")
            }
        case .paymentRequired:
            .server(message: "This needs a Pro license — see Settings → Pro.")
        case .byokKeyInvalid(let provider):
            // Added 2026-09-29 (leaf 1.6.1): APIError gained this case for the
            // BYOK feature and this switch wasn't updated — non-exhaustive.
            .server(message: "Your \(provider) API key was rejected — check it in Settings → API Key.")
        case .pairingCodeExpired, .decoding:
            .server(message: api.errorDescription ?? "Something went wrong loading the dashboard.")
        }
    }
}

// MARK: - Data source protocol

/// Home dashboard data. `greeting()` is local and synchronous — it never
/// throws and never needs the network. The rest are independent async calls
/// so the view model can load (and fail) each section on its own.
protocol DashboardData {
    func greeting() -> DashboardGreeting
    func activeAgent() async throws -> ActiveAgentInfo
    func todaysThreads() async throws -> [ThreadSummary]
    func memorySummary() async throws -> MemorySummary
}

// MARK: - Mock (previews / offline dev)

/// Mock data source. `mode` drives every section, so previews can show the
/// loaded, empty, offline, unpaired, and error states — the loud-failure
/// states G3 requires.
struct MockDashboardData: DashboardData {
    enum Mode {
        case loaded
        case empty
        case offline
        case unpaired
        case error
    }

    let mode: Mode
    let userName: String

    init(mode: Mode = .loaded, userName: String = "there") {
        self.mode = mode
        self.userName = userName
    }

    func greeting() -> DashboardGreeting {
        DashboardGreeting(salutation: "Good morning", userName: userName)
    }

    func activeAgent() async throws -> ActiveAgentInfo {
        switch mode {
        case .loaded:
            ActiveAgentInfo(
                isActive: true,
                activeRunCount: 2,
                currentModel: "claude-opus-4-6",
                currentThreadID: "thread_abc123"
            )
        case .empty:
            .idle
        case .offline:
            throw DashboardError.offline
        case .unpaired:
            throw DashboardError.notPaired
        case .error:
            throw DashboardError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func todaysThreads() async throws -> [ThreadSummary] {
        switch mode {
        case .loaded:
            let now = Date.now
            return [
                ThreadSummary(
                    id: "thread_abc123",
                    title: "Fix Nuitka freeze flags",
                    status: "busy",
                    updatedAt: now.addingTimeInterval(-1_800)
                ),
                ThreadSummary(
                    id: "thread_def456",
                    title: "Upwork proposals",
                    status: "idle",
                    updatedAt: now.addingTimeInterval(-7_200)
                ),
                ThreadSummary(
                    id: "thread_ghi789",
                    title: "",
                    status: "idle",
                    updatedAt: now.addingTimeInterval(-18_000)
                ),
            ]
        case .empty:
            []
        case .offline:
            throw DashboardError.offline
        case .unpaired:
            throw DashboardError.notPaired
        case .error:
            throw DashboardError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func memorySummary() async throws -> MemorySummary {
        switch mode {
        case .loaded:
            MemorySummary(
                factCount: 128,
                topCategories: [
                    MemoryCategoryCount(category: "project", count: 54),
                    MemoryCategoryCount(category: "preference", count: 31),
                    MemoryCategoryCount(category: "person", count: 18),
                ],
                latestFact: "Prefers magenta accents over generic black."
            )
        case .empty:
            .empty
        case .offline:
            throw DashboardError.offline
        case .unpaired:
            throw DashboardError.notPaired
        case .error:
            throw DashboardError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }
}

// MARK: - Unpaired (phone isn't paired yet)

/// Greeting still works (it's local); everything else throws `.notPaired` so
/// views render the pairing prompt — never a spinner, never a blank screen.
struct UnpairedDashboardData: DashboardData {
    let userName: String

    func greeting() -> DashboardGreeting {
        DashboardGreeting(salutation: "Good morning", userName: userName)
    }

    func activeAgent() async throws -> ActiveAgentInfo {
        throw DashboardError.notPaired
    }

    func todaysThreads() async throws -> [ThreadSummary] {
        throw DashboardError.notPaired
    }

    func memorySummary() async throws -> MemorySummary {
        throw DashboardError.notPaired
    }
}

// MARK: - Live (real gateway endpoints)

// Backend DTOs, private: they match the verified wire shapes. Two known
// drifts vs the shared models in Core/API/Models.swift (another leaf's file,
// intentionally not touched here):
//  1. `AgentStatus` there expects `active_runs` as an Int plus `queue_depth`
//     and `model`; the backend actually sends `active_count: Int` and
//     `active_runs: [ActiveRunInfo]`. Decoded tolerantly here.
//  2. `ThreadResponse` there has no `values`; thread titles live at
//     `values.title` (this is what the web frontend reads). Decoded tolerantly
//     here.

/// GET /api/remote/v1/agent/status →
/// {server_time: float, active_count: int,
///  active_runs: [{run_id, thread_id, status, model_name?}]}
/// (backend/app/gateway/routers/remote_control.py, AgentStatusResponse)
private struct AgentStatusDTO: Decodable {
    struct ActiveRun: Decodable {
        let run_id: String?
        let thread_id: String?
        let status: String?
        let model_name: String?
    }

    let active_count: Int?
    let active_runs: [ActiveRun]?
}

/// POST /api/threads/search → [{thread_id, status, created_at, updated_at,
/// metadata, values, interrupts}] (backend/app/gateway/routers/threads.py,
/// ThreadResponse). Only the fields Home needs are decoded; `values.title`
/// is read tolerantly because `values` is an open-ended state dict.
private struct ThreadListItemDTO: Decodable {
    let thread_id: String
    let status: String?
    let created_at: String?
    let updated_at: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case thread_id, status, created_at, updated_at, values
    }

    enum ValuesKeys: String, CodingKey {
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread_id = try container.decode(String.self, forKey: .thread_id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        created_at = try container.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try container.decodeIfPresent(String.self, forKey: .updated_at)
        if let values = try? container.nestedContainer(keyedBy: ValuesKeys.self, forKey: .values) {
            title = try values.decodeIfPresent(String.self, forKey: .title)
        } else {
            title = nil
        }
    }
}

private let isoFormatter = ISO8601DateFormatter()

/// Real gateway data source. Endpoint shapes verified 2026-09-29 against
/// backend/app/gateway/routers/{remote_control,threads,memory}.py.
struct LiveDashboardData: DashboardData {
    let api: APIClient
    let userName: String

    func greeting() -> DashboardGreeting {
        .current(userName: userName)
    }

    func activeAgent() async throws -> ActiveAgentInfo {
        let dto: AgentStatusDTO = try await api.get(Endpoints.Remote.agentStatus)
        let runs = dto.active_runs ?? []
        let count = dto.active_count ?? runs.count
        let first = runs.first
        return ActiveAgentInfo(
            isActive: count > 0,
            activeRunCount: count,
            currentModel: first?.model_name,
            currentThreadID: first?.thread_id
        )
    }

    func todaysThreads() async throws -> [ThreadSummary] {
        var request = ThreadSearchRequest()
        request.limit = 50
        let items: [ThreadListItemDTO] = try await api.post(Endpoints.Threads.search, body: request)
        let calendar = Calendar.current
        return items
            .compactMap { item -> ThreadSummary? in
                let updatedAt = item.updated_at.flatMap { isoFormatter.date(from: $0) }
                return ThreadSummary(
                    id: item.thread_id,
                    title: item.title ?? "",
                    status: item.status ?? "idle",
                    updatedAt: updatedAt
                )
            }
            // "Today's" threads: only ones provably touched today. Undated
            // threads are excluded rather than mislabeled.
            .filter { summary in
                guard let updatedAt = summary.updatedAt else { return false }
                return calendar.isDateInToday(updatedAt)
            }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func memorySummary() async throws -> MemorySummary {
        // GET /api/memory → {facts: [{id, content, category, confidence,
        // createdAt, source, sourceError?}]} — shape verified against
        // backend/app/gateway/routers/memory.py (see Endpoints.Memory).
        let response: MemoryResponse = try await api.get(Endpoints.Memory.get)
        let facts = response.facts ?? []
        var counts: [String: Int] = [:]
        for fact in facts {
            counts[fact.category, default: 0] += 1
        }
        let top = counts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { MemoryCategoryCount(category: $0.key, count: $0.value) }
        return MemorySummary(
            factCount: facts.count,
            topCategories: top,
            latestFact: facts.first?.content
        )
    }
}
