import Foundation

// MARK: - Run models (leaf 1.3.1)
//
// Core run types for the Runs tab (contract §4) and Run detail (contract §5).
// Wire shapes verified 2026-09-29 against:
//   backend/packages/harness/deerflow/runtime/runs/schemas.py  (RunStatus)
//   backend/app/gateway/routers/thread_runs.py                 (RunResponse, events, cancel)
//
// Contract-driven types with NO backend source (VerificationEvidence,
// FrozenCandidate, ReviewerResult, RiskTier) are explicitly marked mock-only
// below — they exist because REDESIGN-CONTRACT.md §5 renders them, not
// because any endpoint returns them.

// MARK: - Run status

/// Lifecycle status of a single run, from the backend `RunStatus` StrEnum
/// (schemas.py). Decodes tolerantly: unknown future values become
/// `.unknown(raw)` instead of failing the whole payload.
enum RunStatus: Equatable {
    case pending
    case running
    case success
    case error
    case timeout
    case interrupted
    case unknown(String)

    init(raw: String) {
        switch raw.lowercased() {
        case "pending": self = .pending
        case "running": self = .running
        case "success": self = .success
        case "error": self = .error
        case "timeout": self = .timeout
        case "interrupted": self = .interrupted
        default: self = .unknown(raw)
        }
    }

    /// Terminal states never change again — the timeline stops listening.
    var isTerminal: Bool {
        switch self {
        case .success, .error, .timeout, .interrupted: true
        case .pending, .running, .unknown: false
        }
    }

    /// Human-readable badge text (contract §4 card: Running / Frozen /
    /// Failed / Pending). "Frozen" is a UI interpretation of an interrupted
    /// run that can be resumed; the backend sends `interrupted`.
    var badgeText: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .success: "Succeeded"
        case .error: "Failed"
        case .timeout: "Timed out"
        case .interrupted: "Frozen"
        case .unknown(let raw): raw
        }
    }
}

// MARK: - Risk tier

/// MOCK-ONLY. No backend endpoint returns a risk tier — this is a
/// contract-§5 design concept (Risk Tier card: MEDIUM + bullets). Live data
/// sources leave it `nil` unless the backend starts sending it in `metadata`.
enum RiskTier: String, Codable, CaseIterable, Equatable {
    case low
    case medium
    case high
    case critical

    var badgeText: String { rawValue.uppercased() }
}

// MARK: - Run step

/// One timeline step, from GET /{thread_id}/runs/{run_id}/events when the
/// backend emits step-like events; otherwise synthesized by the provider
/// from the run's status (see RunsProviders.swift).
struct RunStep: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case active
        case done
        case failed
        case skipped
    }

    let id: String
    let index: Int // 0-based position in the timeline
    let name: String
    let state: State
    let startedAt: Date?
    let endedAt: Date?
}

// MARK: - Verification evidence

/// MOCK-ONLY. No backend endpoint returns pytest suites, security scans, or
/// policy replays — contract §5 renders this card, so the type exists for
/// the mock provider and (later) any real verification feed. Live providers
/// always return an empty evidence list.
struct VerificationEvidence: Identifiable, Equatable {
    enum Result: Equatable {
        case passed
        case failed
        case pending
        case warning
    }

    let id: String
    let name: String // "Pytest Suite", "Security Scan", …
    let result: Result
    /// Human detail, e.g. "926 passed" or "Clean".
    let detail: String
}

// MARK: - Frozen candidate

/// MOCK-ONLY. Contract §5 "Frozen Candidate" card (hash, frozen-at,
/// approvals, review state). No backend endpoint returns this shape.
struct FrozenCandidate: Equatable {
    let hash: String
    let frozenAt: Date?
    let approvals: Int
    let approvalsRequired: Int
    let reviewState: String // "Under Review", "Approved", …
}

// MARK: - Reviewer result

/// MOCK-ONLY. Contract §5 "Reviewer Results" card. No backend endpoint
/// returns reviewer state.
struct ReviewerResult: Identifiable, Equatable {
    let id: String
    let reviewerName: String // "Reviewer 1"
    let state: String // "In Progress", "Pending", "Approved"
    let note: String?
}

// MARK: - Run summary (list row)

/// One run, as shown on the Runs list (contract §4). Built from
/// GET /api/threads/{thread_id}/runs → RunResponse.
struct RunSummary: Identifiable, Equatable {
    let id: String // run_id
    let threadID: String
    /// Human objective/title; falls back to a truncated run id when the
    /// backend sent nothing usable (never blank in the UI).
    let objective: String
    let status: RunStatus
    /// Nil from live providers until the backend sends a risk tier.
    let riskTier: RiskTier?
    /// 0.0–1.0 when the backend reports progress; nil means indeterminate.
    let progress: Double?
    /// Current step position, 1-based when known.
    let stepIndex: Int?
    let stepTotal: Int?
    let currentStepName: String?
    let model: String?
    let startedAt: Date?
    let updatedAt: Date?
    let messageCount: Int
    let totalTokens: Int

    var displayObjective: String {
        objective.isEmpty ? "Run \(id.prefix(8))" : objective
    }

    /// "Step 4 of 11", or nil when the position is unknown.
    var stepText: String? {
        guard let index = stepIndex, let total = stepTotal else { return nil }
        return "Step \(index) of \(total)"
    }
}

// MARK: - Run detail (detail screen)

/// Full run detail for contract §5. `steps` come from the events endpoint
/// (or a status-derived fallback); `evidence`, `frozenCandidate`, and
/// `reviewers` are mock-only until a backend feed exists.
struct RunDetail: Equatable {
    let summary: RunSummary
    let steps: [RunStep]
    let evidence: [VerificationEvidence]
    let frozenCandidate: FrozenCandidate?
    /// Risk bullets, e.g. ["Self-Improving Code", "Canary Deployment",
    /// "Rollback Ready"] (contract §5 card 5).
    let riskBullets: [String]
    let reviewers: [ReviewerResult]
}
