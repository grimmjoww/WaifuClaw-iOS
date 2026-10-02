import Foundation

/// The fixed upstream `nmem_*` vocabulary audited at NeuralMemory SHA
/// `2015cb9b0973a6fe14a3bc547c932d64d6ced203`.
///
/// This enum is deliberately broader than the iOS allowlist. Listing a name
/// here does not advertise, authorize, or implement it. The registry exposes
/// only its two explicitly supported read-only cases.
enum NativeMemoryUpstreamTool: String, CaseIterable, Sendable, Hashable {
    case remember = "nmem_remember"
    case rememberBatch = "nmem_remember_batch"
    case recall = "nmem_recall"
    case show = "nmem_show"
    case context = "nmem_context"
    case todo = "nmem_todo"
    case auto = "nmem_auto"
    case suggest = "nmem_suggest"
    case session = "nmem_session"
    case eternal = "nmem_eternal"
    case recap = "nmem_recap"
    case provenance = "nmem_provenance"
    case source = "nmem_source"
    case stats = "nmem_stats"
    case health = "nmem_health"
    case evolution = "nmem_evolution"
    case habits = "nmem_habits"
    case narrative = "nmem_narrative"
    case hypothesize = "nmem_hypothesize"
    case evidence = "nmem_evidence"
    case predict = "nmem_predict"
    case verify = "nmem_verify"
    case cognitive = "nmem_cognitive"
    case gaps = "nmem_gaps"
    case schema = "nmem_schema"
    case explain = "nmem_explain"
    case train = "nmem_train"
    case trainDatabase = "nmem_train_db"
    case index = "nmem_index"
    case importMemories = "nmem_import"
    case edit = "nmem_edit"
    case forget = "nmem_forget"
    case pin = "nmem_pin"
    case consolidate = "nmem_consolidate"
    case drift = "nmem_drift"
    case review = "nmem_review"
    case alerts = "nmem_alerts"
    case sync = "nmem_sync"
    case syncStatus = "nmem_sync_status"
    case syncConfiguration = "nmem_sync_config"
    case telegramBackup = "nmem_telegram_backup"
    case version = "nmem_version"
    case transplant = "nmem_transplant"
    case conflicts = "nmem_conflicts"
    case reflex = "nmem_reflex"
    case visualize = "nmem_visualize"
    case watch = "nmem_watch"
    case surface = "nmem_surface"
    case toolStats = "nmem_tool_stats"
    case lifecycle = "nmem_lifecycle"
    case refine = "nmem_refine"
    case reportOutcome = "nmem_report_outcome"
    case budget = "nmem_budget"
    case tier = "nmem_tier"
    case boundaries = "nmem_boundaries"
    case milestone = "nmem_milestone"
    case store = "nmem_store"
    case goal = "nmem_goal"
    case causal = "nmem_causal"
    case cache = "nmem_cache"
    case offload = "nmem_offload"
    case inflate = "nmem_inflate"
    case situation = "nmem_situation"
}

/// The only upstream names presently implemented in the native allowlist.
/// They are both read-only and have no network or mutation capability.
enum NativeMemoryNativeTool: String, CaseIterable, Sendable, Hashable {
    case recall = "nmem_recall"
    case show = "nmem_show"

    init?(upstreamTool: NativeMemoryUpstreamTool) {
        self.init(rawValue: upstreamTool.rawValue)
    }
}

/// Privacy inputs supplied by the parent agent immediately before tools are
/// offered and again immediately before a call is dispatched. `requestedProjectID`
/// must be derived from the same user-selected project request as the selected ID;
/// it is not model-controlled tool input.
struct NativeMemoryToolAccessContext: Sendable, Hashable {
    let selectedProjectID: String?
    let requestedProjectID: String?
    let hasModelSharingConsent: Bool

    init(
        selectedProjectID: String?,
        requestedProjectID: String?,
        hasModelSharingConsent: Bool
    ) {
        self.selectedProjectID = selectedProjectID
        self.requestedProjectID = requestedProjectID
        self.hasModelSharingConsent = hasModelSharingConsent
    }
}

/// A policy result is value-typed so the registry and dispatcher must apply
/// exactly the same project/consent gate. The associated project ID is never
/// serialized to the model.
enum NativeMemoryToolAvailability: Sendable, Equatable {
    case available(projectID: String)
    case unavailable(NativeMemoryToolErrorCode)
}

/// Stable, model-safe error categories. Error payloads never contain database
/// paths, raw SQLite errors, credentials, or another project's identifiers.
enum NativeMemoryToolErrorCode: String, Codable, Sendable, Equatable {
    case projectNotSelected = "project_not_selected"
    case invalidProjectScope = "invalid_project_scope"
    case projectMismatch = "project_mismatch"
    case consentNotGranted = "consent_not_granted"
    case unsupportedTool = "unsupported_tool"
    case unavailableTool = "unavailable_tool"
    case invalidJSON = "invalid_json"
    case invalidArguments = "invalid_arguments"
    case unsupportedField = "unsupported_field"
    case invalidField = "invalid_field"
    case invalidMemoryID = "invalid_memory_id"
    case memoryNotFound = "memory_not_found"
    case cancelled = "cancelled"
    case localReadFailed = "local_read_failed"
}

/// A redacted event description the parent agent can append to `LocalRunStore`.
/// The dispatcher owns the event kind and summary so success/failure cannot be
/// inferred from a model-generated string.
struct NativeMemoryToolRunEffect: Sendable, Hashable {
    let kind: String
    let summary: String

    init(kind: String, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

/// The exact tool result to place in an `AgentPromptMessage(role: "tool", ...)`
/// plus the durable lifecycle evidence the parent must append for that call.
struct NativeMemoryToolDispatchResult: Sendable, Hashable {
    let responseJSON: String
    let effects: [NativeMemoryToolRunEffect]
    let succeeded: Bool

    init(
        responseJSON: String,
        effects: [NativeMemoryToolRunEffect],
        succeeded: Bool
    ) {
        self.responseJSON = responseJSON
        self.effects = effects
        self.succeeded = succeeded
    }
}

/// Typed subset of the upstream `nmem_recall` request. The local implementation
/// supports only a query and an explicit 0...3 local graph-hop depth. All other
/// upstream fields, including injected `compact` and `token_budget`, are rejected.
struct NativeMemoryRecallToolRequest: Decodable, Sendable, Hashable {
    let query: String
    let depth: Int?
}

/// Typed subset of the upstream `nmem_show` request. The local store accepts a
/// UUID fact ID only; upstream fiber/neuron ID aliases are not present on iOS.
struct NativeMemoryShowToolRequest: Decodable, Sendable, Hashable {
    let memoryID: String

    enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id"
    }
}
