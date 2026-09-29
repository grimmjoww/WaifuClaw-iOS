import Foundation

// MARK: - Team data contract (leaf 1.4.1)
//
// Views (leaves 1.4.2/1.4.3) depend ONLY on `TeamData` — never on APIClient.
// Two implementations ship:
//   - `MockTeamData`  previews / offline development (see MockTeamData.swift),
//                       with loud-failure modes
//   - `LiveTeamData`  real gateway endpoints, verified 2026-09-29 against
//                       backend/app/gateway/routers/{agents,threads,
//                       thread_runs}.py.
//
// Endpoint honesty (G3): every live method cites the exact backend route.
// GET /api/agents has NO constant in Core/API/Endpoints.swift yet (another
// leaf's file — not touched here); it is called by literal path with the
// route cited in comments. This is NOT an invented contract — the route was
// read verbatim from agents.py:107.
//
// What the backend does NOT have (so these stay mock-only, explicitly):
//   - no task/kanban endpoint at all → TeamBoard, TeamTask, TeamTaskDetail
//   - no presence/status feed for agents → MemberPresence (live: .unknown)
//   - no milestones/achievements feed → Milestone
//   - no inbox feed → InboxItem is *derived* from recent threads (real
//     threads, real latest-message snippets — not a dedicated feed).

// MARK: - Errors

/// User-facing team errors. Every case has a message a human can act on.
enum TeamError: LocalizedError, Equatable {
    case notPaired
    case offline
    case sessionExpired
    /// GET /api/agents answered 403: the desktop's agent directory API is
    /// disabled (agents_api.enabled=false). Loud and actionable — never a
    /// blank rail.
    case agentsDisabled
    /// The board/task detail has no backend feed yet (mock-only surface).
    case notSupported
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "No computer paired — pair your desktop to load your team."
        case .offline:
            "Can't reach your computer — check it's awake and on the same network."
        case .sessionExpired:
            "Your session expired — pair again to reconnect."
        case .agentsDisabled:
            "The agent directory is off on your computer — enable agents_api.enabled in its config to see your team."
        case .notSupported:
            "Tasks live on the desktop roadmap — the board is a preview until your computer ships a task feed."
        case .server(let message):
            message
        }
    }

    /// Maps transport errors to team errors. `CancellationError` is never
    /// mapped here — callers filter it first, because a cancelled load is a
    /// normal lifecycle event, not a failure (bug-patterns.md).
    static func describe(_ error: Error) -> TeamError {
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
            } else if status == 403 {
                .agentsDisabled
            } else if status == 404 {
                .server(message: "That thread no longer exists on your computer.")
            } else {
                .server(message: message ?? "The desktop returned an error (HTTP \(status)).")
            }
        case .paymentRequired:
            .server(message: "This needs a Pro license — see the License tab.")
        case .pairingCodeExpired, .decoding:
            .server(message: api.errorDescription ?? "Something went wrong loading the team.")
        case .byokKeyInvalid:
            .server(message: api.errorDescription ?? "Something went wrong loading the team.")
        }
    }
}

// MARK: - Data source protocol

/// Team data. The async calls are independent so the view model can load
/// (and fail) the roster, the conversations, and the board on their own.
///
/// The protocol serves BOTH presentations: `board()`/`taskDetail(_:)` feed
/// the kanban board (contract §6–§7, mock-only backing), while
/// `conversations(limit:)`/`messages(threadID:limit:)` feed the
/// conversational agent-to-agent view (live-backed). `inboxItems(limit:)`
/// bridges the two: real threads with real latest-message snippets.
protocol TeamData {
    /// Agent roster for the Active Agents rail.
    func members() async throws -> [TeamMember]
    /// Recent threads, newest first — the conversation list.
    func conversations(limit: Int) async throws -> [TeamConversation]
    /// Messages in one thread, in backend order.
    func messages(threadID: String, limit: Int) async throws -> [TeamMessage]
    /// Team Inbox rows: recent threads + latest-message snippet each.
    func inboxItems(limit: Int) async throws -> [InboxItem]
    /// Kanban board. MOCK-ONLY backing — live returns an empty board
    /// (documented, not a failure).
    func board() async throws -> TeamBoard
    /// Task detail. MOCK-ONLY backing — live throws `.notSupported`, loudly.
    func taskDetail(id: String) async throws -> TeamTaskDetail
    /// Milestones & Achievements tiles. MOCK-ONLY backing — live returns [].
    func milestones() async throws -> [Milestone]
}

// MARK: - DTOs (private wire shapes)

/// GET /api/agents → {"agents": [...]} (agents.py:107).
private struct AgentsListDTO: Decodable {
    let agents: [AgentDTO]
}

/// agents.py:23. `soul` is deliberately NOT decoded — it can be kilobytes
/// of persona text the phone never renders.
private struct AgentDTO: Decodable {
    let name: String
    let description: String?
    let model: String?
    let skills: [String]?

    enum CodingKeys: String, CodingKey {
        case name, description, model, skills
    }
}

/// POST /api/threads/search item → ThreadResponse (threads.py:64), trimmed
/// to what the team UI needs.
private struct ThreadDTO: Decodable {
    let thread_id: String
    let status: String?
    let created_at: String?
    let updated_at: String?
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case thread_id, status, created_at, updated_at, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread_id = try container.decode(String.self, forKey: .thread_id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        created_at = try container.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try container.decodeIfPresent(String.self, forKey: .updated_at)
        // metadata is dict[str, Any] on the wire — keep only string values;
        // anything else is irrelevant to title lookup.
        metadata = (try? container.decode([String: String].self, forKey: .metadata)) ?? [:]
    }
}

/// CodingKey that accepts any string key (for open-ended content dicts).
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// GET /api/threads/{id}/messages item (thread_runs.py:757). The wire shape
/// is `list[dict]` — open-ended event-store rows — so every field is
/// optional and content may be a bare string or a dict.
private struct MessageDTO: Decodable {
    let eventType: String?
    let runID: String?
    let seq: Int?
    let createdAt: String?
    let authorName: String?
    let contentType: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case runID = "run_id"
        case seq
        case createdAt = "created_at"
        case content
        case author
        case authorName = "author_name"
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        authorName = (try container.decodeIfPresent(String.self, forKey: .author))
            ?? (try container.decodeIfPresent(String.self, forKey: .authorName))
            ?? (try container.decodeIfPresent(String.self, forKey: .name))
        // Content: bare string, or a dict carrying type/text under various keys.
        let content: ContentDTO? = try? container.decodeIfPresent(ContentDTO.self, forKey: .content)
        contentType = content?.type
        text = content?.text
    }
}

/// The `content` value of a message row: string or dict, decoded tolerantly.
private struct ContentDTO: Decodable {
    let type: String?
    let text: String?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            self.type = nil
            self.text = string
            return
        }
        if let nested = try? single.nestedContainer(keyedBy: AnyKey.self) {
            func string(_ key: String) -> String? {
                try? nested.decodeIfPresent(String.self, forKey: AnyKey(key))
            }
            self.type = string("type")
            self.text = string("text") ?? string("content") ?? string("message") ?? string("output")
            return
        }
        self.type = nil
        self.text = nil
    }
}

private let teamISOFormatter = ISO8601DateFormatter()

// MARK: - Live (real gateway endpoints)

/// Real gateway data source.
struct LiveTeamData: TeamData {
    let api: APIClient

    // MARK: Roster

    /// GET /api/agents (agents.py:107). The whole router 403s when the
    /// desktop has agents_api.enabled=false — that becomes the loud
    /// `.agentsDisabled` error, never a blank rail.
    func members() async throws -> [TeamMember] {
        let dto: AgentsListDTO
        do {
            dto = try await api.get("/api/agents")
        } catch let apiError as APIError {
            if case .http(403, _) = apiError {
                throw TeamError.agentsDisabled
            }
            throw apiError
        }
        return dto.agents.map(Self.member(from:))
    }

    // MARK: Conversations

    /// POST /api/threads/search (Endpoints.Threads.search, threads.py:321).
    func conversations(limit: Int) async throws -> [TeamConversation] {
        var request = ThreadSearchRequest()
        request.limit = min(max(limit, 1), 50)
        let dtos: [ThreadDTO] = try await api.post(Endpoints.Threads.search, body: request)
        let convos = dtos.map(Self.conversation(from:))
        let sorted = convos.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return Array(sorted.prefix(limit))
    }

    /// GET /api/threads/{thread_id}/messages?limit=N
    /// (Endpoints.Threads.messages, thread_runs.py:757).
    func messages(threadID: String, limit: Int) async throws -> [TeamMessage] {
        let dtos: [MessageDTO] = try await api.get(
            Endpoints.Threads.messages(threadID) + "?limit=\(min(max(limit, 1), 200))"
        )
        return dtos.enumerated().map { index, dto in
            Self.message(from: dto, threadID: threadID, index: index)
        }
    }

    /// Recent threads with each thread's latest message as the snippet.
    /// Bounded fan-out (5 threads max): one thread failing yields a nil
    /// snippet, not a failed inbox. Cancellation still propagates.
    func inboxItems(limit: Int) async throws -> [InboxItem] {
        let convos = try await conversations(limit: limit)
        var items: [InboxItem] = []
        for convo in convos.prefix(5) {
            let snippet: String?
            do {
                snippet = try await messages(threadID: convo.id, limit: 1).first?.displayText
            } catch is CancellationError {
                throw // A cancelled load is a lifecycle event, not a failure.
            } catch {
                snippet = nil
            }
            items.append(InboxItem(
                id: convo.id,
                title: convo.displayTitle,
                snippet: snippet,
                updatedAt: convo.updatedAt
            ))
        }
        return items
    }

    // MARK: Mock-only surfaces

    /// MOCK-ONLY. The backend has no task system, so the live board is
    /// honestly empty — the screen shows the contract's empty states.
    func board() async throws -> TeamBoard {
        .empty
    }

    /// MOCK-ONLY. No backend source — loud `.notSupported`, never a fake.
    func taskDetail(id: String) async throws -> TeamTaskDetail {
        throw TeamError.notSupported
    }

    /// MOCK-ONLY. No backend source — live returns no milestones.
    func milestones() async throws -> [Milestone] {
        []
    }

    // MARK: Mapping

    private static func member(from dto: AgentDTO) -> TeamMember {
        let role = (dto.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return TeamMember(
            id: dto.name,
            displayName: TeamMember.displayName(for: dto.name),
            role: role.isEmpty ? "Agent" : role,
            model: dto.model,
            skills: dto.skills,
            presence: .unknown // No presence feed in the backend (see TeamModels).
        )
    }

    private static func conversation(from dto: ThreadDTO) -> TeamConversation {
        let title = dto.metadata["objective"] ?? dto.metadata["title"] ?? ""
        return TeamConversation(
            id: dto.thread_id,
            title: title,
            status: ConversationStatus(raw: dto.status ?? "idle"),
            updatedAt: dto.updatedAt.flatMap { teamISOFormatter.date(from: $0) },
            createdAt: dto.createdAt.flatMap { teamISOFormatter.date(from: $0) }
        )
    }

    private static func message(from dto: MessageDTO, threadID: String, index: Int) -> TeamMessage {
        let id: String
        if let seq = dto.seq {
            id = "\(threadID)-\(seq)"
        } else {
            id = "\(threadID)-\(index)"
        }
        return TeamMessage(
            id: id,
            threadID: threadID,
            role: MessageRole(eventType: dto.eventType, contentType: dto.contentType),
            text: dto.text ?? "",
            runID: dto.runID,
            createdAt: dto.createdAt.flatMap { teamISOFormatter.date(from: $0) },
            authorName: dto.authorName
        )
    }
}
