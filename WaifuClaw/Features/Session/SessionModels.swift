import Foundation

// MARK: - Session event (terminal line)
//
// A stored run event or a live SSE frame, reduced to one human-readable
// terminal line. The backend stores events as open dicts
// (journal.py `_put`: event_type / category / content / metadata /
// created_at); the live join stream emits LangGraph SSE frames. Both are
// normalized here so the terminal renders one honest line per event.

/// One line in the session terminal.
struct SessionEvent: Identifiable, Sendable, Equatable {
    /// "stored-<index>" for backlog events, "live-<index>" for stream frames.
    let id: String
    let occurredAt: Date?
    /// Backend `event_type` ("llm.tool.result") or SSE event name.
    let kind: String
    /// One-line human-readable summary, never raw JSON dumps.
    let summary: String
    let isError: Bool
}

// MARK: - Stream phase

/// Connection phase of the session terminal. Always rendered as a visible
/// StatusBadge — the user must see at a glance whether the stream is live.
enum SessionStreamPhase: Equatable {
    /// Opening (or re-opening) the SSE stream.
    case connecting
    /// Stream open, frames arriving.
    case live
    /// User paused the stream; the task is cancelled, nothing is fetched.
    case paused
    /// The run reached a terminal state (or the desktop reports it is not
    /// active on this worker): backlog only, no stream attempted.
    case ended
    /// Transport failure that looks like no connectivity.
    case offline
    /// Loud failure with the backend's message; offers Reconnect.
    case failed(String)
}

// MARK: - Skill receipts ("Tools" section)
//
// Backed by GET /api/threads/{t}/runs/{r}/skill-receipts
// (thread_runs.py): the host-safe, read-only skill lifecycle projection
// for a run. Only fields the phone renders are decoded.

/// One skill execution receipt for a run.
struct SkillReceipt: Identifiable, Sendable, Equatable {
    /// Backend `receipt_id`.
    let id: String
    let skillName: String
    let category: String
    /// Backend `current_state`; nil when the backend sent none.
    let state: String?
    let requiresAttention: Bool
    let eventCount: Int
}

/// The skill-receipts envelope: receipts plus the backend's own signal
/// about whether telemetry exists at all.
struct SkillReceiptList: Sendable, Equatable {
    let receipts: [SkillReceipt]
    /// False means the run emitted no skill telemetry — the UI says so
    /// instead of rendering an empty list.
    let telemetryAvailable: Bool
    let hasMore: Bool
}
