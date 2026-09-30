# Native `nmem_*` Read-Only Tool Boundary

**Status: two native read-only tools are implemented; this is not 63-tool NeuralMemory parity.**

The source-audited upstream vocabulary has **63** names at SHA `2015cb9b0973a6fe14a3bc547c932d64d6ced203`. `NativeMemoryUpstreamTool` intentionally records those names so a stale or malicious provider call can be classified, but `NativeMemoryToolRegistry` advertises exactly these two allowlisted handlers:

| Public tool name | Native iOS support |
|---|---|
| `nmem_recall` | Read approved facts from the selected project's `LocalNeuralMemoryStore` using local token anchors and bounded co-occurrence spreading. |
| `nmem_show` | Read one approved fact UUID from that same store/project and bounded same-project co-occurrence edges. |

All other upstream `nmem_*` names return an explicit `unsupported_tool` error **if a parent chooses to pass them to this dispatcher**, but are never offered. They have no native handler, no write authority, and no network fallback.

## Exact signatures for the parent agent

```swift
let access = NativeMemoryToolAccessContext(
    selectedProjectID: selectedProjectID,
    requestedProjectID: selectedProjectID,
    hasModelSharingConsent: NativeMemoryConsent().isEnabled(for: selectedProjectID)
)

let offeredMemoryTools: [AgentToolDefinition] =
    NativeMemoryToolRegistry.definitions(for: access)

let memoryDispatcher = NativeMemoryToolDispatcher(memoryStore: realLocalNeuralMemoryStore)

let outcome: NativeMemoryToolDispatchResult = await memoryDispatcher.dispatch(
    call,
    access: access
)
// `outcome.responseJSON` is the exact text for AgentPromptMessage(role: "tool", ...).
// `outcome.succeeded` is the authoritative terminal status.
// `outcome.effects` are the authoritative run-event records.
```

The exact call overload is:

```swift
func dispatch(
    _ call: AgentToolCall,
    access: NativeMemoryToolAccessContext
) async -> NativeMemoryToolDispatchResult

func dispatch(
    name: String,
    argumentsJSON: String,
    access: NativeMemoryToolAccessContext
) async -> NativeMemoryToolDispatchResult
```

## Current `NativeAgentEngine` integration

`NativeAgentEngine.perform` derives the scope from the user-selected Files folder. It offers only `nmem_recall` and `nmem_show`, only when a real local memory store is available, this run permits memory, and the current selected project has explicit provider-sharing consent. It rechecks project identity and consent immediately before each call, dispatches through the local store, appends the dispatcher's selected/terminal receipts to the real run, and passes the bounded JSON response back to the model. Unsupported `nmem_*` calls are explicitly refused; they are never offered or passed to file tools.

The XCTest-only scripted provider in `NativeAgentEngineTests.testConsentedNativeMemoryToolsRunInsideRealAgentLifecycle` exercises actual tool offers, project-scoped SQLite lookup and persisted run receipts. Until macOS simulator tests pass, this is **source-level integration, not verified runtime parity**; the other 61 upstream tool names remain unsupported, and these two handlers implement documented narrow local subsets rather than exact upstream contracts.

## Consent, scope, and safety boundary

`NativeMemoryToolRegistry.definitions(for:)` returns an empty array, and dispatcher execution does not touch the store, unless all are true:

- a canonical 64-character lowercase-hex user-selected project identity exists;
- `requestedProjectID` exactly equals that selected project identity; and
- explicit per-project provider-sharing consent is currently true.

Failures use a redacted JSON error and a `tool.failed` effect: `project_not_selected`, `invalid_project_scope`, `project_mismatch`, or `consent_not_granted`. A foreign `memory_id` and a missing one both return `memory_not_found`; the response never confirms another project's ownership.

The implementation invokes only `LocalNeuralMemoryStore.recall` and `LocalNeuralMemoryStore.exportProject`. It has no write method, `URLSession`, filesystem operation, credential access, database URL serialization, raw anchor export, provenance reference export, or cross-project query.

## Supported request and response contract

### `nmem_recall`

Bounded schema:

```json
{
  "type": "object",
  "properties": {
    "query": { "type": "string", "minLength": 1, "maxLength": 4000 },
    "depth": { "type": "integer", "minimum": 0, "maximum": 3 }
  },
  "required": ["query"],
  "additionalProperties": false
}
```

- `depth` defaults to **1** and maps directly to local co-occurrence graph hops. It is **not** upstream depth-routing/spreading-activation parity.
- Output is stable for an unchanged store and is capped at **12** facts. Each fact's model-visible content is a **2,000-character** excerpt with `content_truncated` when applicable.
- The output carries only the fact UUID, approved content/excerpt, timestamp, source kind, score, matched anchor tokens, and hop count. It omits free-form source labels/references, `capturedBy`, source-record ID, approval note, database IDs, raw anchors, and raw storage.

Every other upstream recall field is rejected as `unsupported_field`; this includes `mode` (both `associative` and `exact`), `max_tokens`, filters/tags, trust/tier/status/layer/time options, cross-brain `brains`, citations/provenance/paths, `compact`, and injected `token_budget`. Invalid JSON, non-object JSON, nulls, bad types, blank/overlong query, or out-of-range depth yield explicit `invalid_json`, `invalid_arguments`, or `invalid_field` responses.

### `nmem_show`

Bounded schema:

```json
{
  "type": "object",
  "properties": {
    "memory_id": {
      "type": "string",
      "minLength": 36,
      "maxLength": 36,
      "pattern": "^[0-9A-Fa-f-]{36}$"
    }
  },
  "required": ["memory_id"],
  "additionalProperties": false
}
```

- Accepts only a local approved-fact **UUID** returned by native `nmem_recall`. It does not accept upstream fiber IDs or neuron IDs.
- Returns the store-bounded (maximum 10,000-character) verbatim approved fact, creation time, source kind, and only local `co_occurs` connections. It excludes fact→anchor edges so raw anchor storage is not exposed.
- `synapse_count` reports all same-project co-occurrence connections; `synapses` is deterministic and capped at **64**, with `synapses_truncated` when applicable.
- Upstream-injected `compact` and `token_budget` are unsupported and explicitly rejected.

## Material source differences from upstream

Upstream `nmem_recall` implements a much broader pipeline (brain selection/cross-brain lookups, activation configuration, session/knowledge-surface logic, lifecycle, typed-memory filters, exact raw-neuron mode, provenance/audit, optional encryption handling, hooks, passive capture, and response compaction). Upstream `nmem_show` accepts both fiber and neuron IDs and exposes its fiber/neuron metadata and synapses. None of those state models or modes are claimed here.

The native subset is only a project-isolated, on-device SQLite read of **previously user-approved facts**, their deterministic local recall score, and co-occurrence relationships. It does not establish ready status for G03/G04 or any other row in `NEURAL-63-PARITY.md` until the parent completes real agent-cycle routing and lifecycle evidence tests.
