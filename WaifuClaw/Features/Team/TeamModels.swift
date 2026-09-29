import Foundation

// MARK: - Team models (leaf 1.4.1)
//
// Core team types for the Team tab (contract §6) and Task detail
// (contract §7). Wire shapes verified 2026-09-29 against:
//   backend/app/gateway/routers/agents.py         (AgentResponse, GET /api/agents)
//   backend/app/gateway/routers/threads.py        (ThreadResponse, ThreadSearchRequest)
//   backend/app/gateway/routers/thread_runs.py     (GET /{thread_id}/messages)
//   backend/app/gateway/routers/remote_control.py (AgentStatusResponse —
//                                                 active runs, not presence)
//
// Design rule: the models support BOTH the kanban board and the
// conversational agent-to-agent view (Willie leans conversational).
// Threads are the conversation substrate; tasks hang off threads.
//
// Honesty ledger (see TeamProviders.swift for the per-method version):
//   LIVE-BACKED: TeamMember (roster), TeamConversation (threads/search),
//     TeamMessage (thread messages), InboxItem (derived from recent threads).
//   MOCK-ONLY: TeamBoard/TeamTask/TaskColumn counts, TeamTaskDetail,
//     Milestone, and member *presence* (the backend has no presence feed and
//     no task system — contract-driven types, explicitly marked below).

// MARK: - Team member (Active Agents rail, contract §6)

///
/// One agent on the team, from GET /api/agents → AgentResponse
/// (agents.py:23). Decodes tolerantly: unknown future fields are ignored,
/// missing optionals fall back to nil/empty — never a whole-payload failure.
///
struct TeamMember: Identifiable, Equatable, Sendable {
    /// The agent's hyphen-case name, e.g. "generalist-engineer".
    let id: String
    /// Short display name, e.g. "Rei".
    let displayName: String
    /// One-line role from the agent's description, e.g. "Generalist Engineer".
    let role: String
    /// Model override, if the agent pins one.
    let model: String?
    /// Skill whitelist names (nil = all skills enabled).
    let skills: [String]?
    /// What the member appears to be doing right now.
    ///
    /// MOCK-ONLY granularity. The backend has no presence feed:
    /// /api/agents returns the roster, /api/remote/v1/agent/status returns
    /// active *runs* (run_id/thread_id/model — no agent name), and neither
    /// maps a run to a named agent. Live providers set `.unknown`; the
    /// conversational view shows real per-thread status instead.
    let presence: MemberPresence

    /// "Rei" from "rei" / "generalist-engineer" → "Generalist Engineer".
    static func displayName(for name: String) -> String {
        let cleaned = name.replacing("-", with: " ")
        let words = cleaned.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let joined = words.joined(separator: " ")
        // Single-word names read as names ("Rei"); multi-word hyphen names
        // read as roles ("Generalist Engineer") — the role line carries it.
        return joined
    }
}

///
/// Apparent activity of a team member. Live data cannot know this —
/// see TeamMember.presence.
///
enum MemberPresence: Equatable, Sendable {
    case online
    case busy
    case offline
    /// Live roster state: the member exists, activity unknown.
    case unknown

    var badgeText: String {
        switch self {
        case .online: "Online"
        case .busy: "Busy"
        case .offline: "Offline"
        case .unknown: "—"
        }
    }
}

// MARK: - Conversation (threads as the agent-to-agent substrate)

///
/// One thread, from POST /api/threads/search → ThreadResponse
/// (threads.py:64). Status decodes tolerantly: unknown future values become
/// `.unknown(raw)` instead of failing the whole list.
///
struct TeamConversation: Identifiable, Equatable, Sendable {
    /// Backend thread_id.
    let id: String
    /// Human title: metadata objective/title when the backend sent one,
    /// otherwise a truncated thread id (never blank in the UI).
    let title: String
    let status: ConversationStatus
    let updatedAt: Date?
    let createdAt: Date?

    var displayTitle: String {
        title.isEmpty ? "Thread \(id.prefix(8))" : title
    }

    /// The conversational view sorts active work first.
    var isActive: Bool {
        status == .busy || status == .interrupted
    }
}

///
/// Thread lifecycle status, from ThreadResponse.status
/// (threads.py:68 — idle, busy, interrupted, error).
///
enum ConversationStatus: Equatable, Sendable {
    case idle
    case busy
    case interrupted
    case error
    case unknown(String)

    init(raw: String) {
        switch raw.lowercased() {
        case "idle": self = .idle
        case "busy": self = .busy
        case "interrupted": self = .interrupted
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }

    var badgeText: String {
        switch self {
        case .idle: "Idle"
        case .busy: "Active"
        case .interrupted: "Interrupted"
        case .error: "Error"
        case .unknown(let raw): raw
        }
    }
}

// MARK: - Message (one turn in a conversation)

///
/// One displayable message, from GET /api/threads/{id}/messages
/// (thread_runs.py:757). The wire shape is `list[dict]` — open-ended event
/// store rows — so decoding is fully tolerant: unrecognized shapes become a
/// message with empty text rather than killing the thread view.
///
struct TeamMessage: Identifiable, Equatable, Sendable {
    let id: String
    let threadID: String
    let role: MessageRole
    /// Raw text; may be empty when the backend sent a non-text payload.
    let text: String
    let runID: String?
    let createdAt: Date?
    /// The author's display name when the backend carried one (human
    /// messages, agent handoffs); nil otherwise.
    let authorName: String?

    var displayText: String {
        text.isEmpty ? "(empty message)" : text
    }
}

///
/// Who said it, derived tolerantly from the message's `event_type`
/// ("llm.ai.response", …) or its content `type` ("ai", "human", …).
///
enum MessageRole: Equatable, Sendable {
    case user
    case agent
    case tool
    case system
    case unknown

    init(eventType: String?, contentType: String?) {
        let haystack = "\(contentType ?? "") \(eventType ?? "")".lowercased()
        if haystack.contains("human") || haystack.contains("user") {
            self = .user
        } else if haystack.contains("tool") {
            self = .tool
        } else if haystack.contains("system") {
            self = .system
        } else if haystack.contains("ai") || haystack.contains("assistant") || haystack.contains("llm") {
            self = .agent
        } else {
            self = .unknown
        }
    }

    var badgeText: String {
        switch self {
        case .user: "You"
        case .agent: "Agent"
        case .tool: "Tool"
        case .system: "System"
        case .unknown: "—"
        }
    }
}

// MARK: - Inbox item (Team Inbox rows, contract §6)

///
/// One Team Inbox row. Live: derived from recent threads — the thread is
/// real, the snippet is the thread's latest message (bounded fan-out, see
/// TeamProviders). The backend has no inbox/message-feed endpoint, so there
/// is no dedicated unread state; rows open the conversation.
///
struct InboxItem: Identifiable, Equatable, Sendable {
    /// Backend thread_id — tapping the row opens this conversation.
    let id: String
    let title: String
    /// Latest message preview; nil when the thread has no messages yet.
    let snippet: String?
    let updatedAt: Date?
}

// MARK: - Board (kanban — MOCK-ONLY, contract §6)

///
/// Board column. The six columns are the contract's design (§6); the
/// backend has no task system, so column *contents* are mock-only.
///
enum TaskColumn: String, CaseIterable, Equatable, Sendable {
    case inbox
    case planned
    case inProgress
    case review
    case verified
    case deployed

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .planned: "Planned"
        case .inProgress: "In Progress"
        case .review: "Review"
        case .verified: "Verified"
        case .deployed: "Deployed"
        }
    }
}

///
/// Task priority. Tolerant: unknown values become `.unknown`.
///
enum TaskPriority: Equatable, Sendable {
    case low
    case medium
    case high
    case critical
    case unknown(String)

    init(raw: String) {
        switch raw.lowercased() {
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "critical": self = .critical
        default: self = .unknown(raw)
        }
    }

    var badgeText: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        case .unknown(let raw): raw
        }
    }
}

///
/// MOCK-ONLY. One kanban card (contract §6): title, #id, assignee, priority.
/// No backend endpoint returns tasks.
///
struct TeamTask: Identifiable, Equatable, Sendable {
    /// Short numeric id shown as "#642".
    let id: String
    let title: String
    let assignee: String // agent display name
    let priority: TaskPriority
    let column: TaskColumn
    /// The backing conversation, when the task was raised from one —
    /// this is the seam the conversational view uses.
    let threadID: String?
    /// 0.0–1.0, nil when unknown.
    let progress: Double?
}

///
/// MOCK-ONLY. One column's cards, in board order.
///
struct BoardColumn: Equatable, Sendable {
    let column: TaskColumn
    let tasks: [TeamTask]

    var count: Int { tasks.count }
}

///
/// MOCK-ONLY. The whole board, columns in contract §6 order.
///
struct TeamBoard: Equatable, Sendable {
    let columns: [BoardColumn]

    static var empty: TeamBoard {
        TeamBoard(columns: TaskColumn.allCases.map { BoardColumn(column: $0, tasks: []) })
    }

    func tasks(in column: TaskColumn) -> [TeamTask] {
        columns.first(where: { $0.column == column })?.tasks ?? []
    }
}

// MARK: - Task detail (MOCK-ONLY, contract §7)

///
/// MOCK-ONLY. Task detail screen (contract §7): progress, verifications,
/// reviewers, branch, frozen hash, assignee, OutcomeRun mini-status.
/// No backend endpoint returns this shape.
///
struct TeamTaskDetail: Equatable, Sendable {
    let task: TeamTask
    /// 0.0–1.0, nil when unknown.
    let progress: Double?
    let verificationsPassed: Int
    let verificationsTotal: Int
    let reviewersDone: Int
    let reviewersTotal: Int
    /// e.g. "feature/hermes-sage-final".
    let branch: String?
    /// Truncated display hash, e.g. "b732fc…e4f7".
    let frozenHash: String?
    /// Risk badges, e.g. ["Self-Modifying"] (contract §7).
    let riskBadges: [String]
    /// OutcomeRun mini-status line, e.g. "Step 4: Implement".
    let outcomeStepText: String?

    var verificationText: String {
        "\(verificationsPassed)/\(verificationsTotal) passed"
    }

    var reviewerText: String {
        "\(reviewersDone)/\(reviewersTotal) complete"
    }
}

// MARK: - Milestone (MOCK-ONLY, contract §6)

///
/// MOCK-ONLY. Milestones & Achievements tiles (contract §6):
/// "1000 Tasks Completed", "Streak 42 Days Active", … No backend source.
///
struct Milestone: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
}
