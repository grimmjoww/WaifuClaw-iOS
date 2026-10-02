# NeuralMemory 63-tool native parity synthesis

**Scope:** Consolidation of the ten successful, read-only source audits in [`docs/neural-tools/`](neural-tools/). The upstream baseline is the MIT Python MCP implementation at `2015cb9b0973a6fe14a3bc547c932d64d6ced203`; the iOS comparison was taken at commit `cf1e0abae3b438423f9a3feb2c0cb0d567ce027f` before native `nmem_*` routing. This is a pinned audit snapshot, not an automatically updated coverage report.

> **Strict result:** **0/63 verified native-ready tools; 63/63 missing or unverified as exact phone-native parity.**
>
> A tool is verified only when all three conditions hold: (1) material upstream contract and state semantics exist on device, (2) its exact native definition is offered and dispatched in a real `NativeAgentEngine` cycle, and (3) a direct XCTest plus an agent-cycle terminal-state XCTest pass. No scoped tool meets all three conditions. A partial local primitive is **not** verification.

## Audit inputs, treatment, and exact counts

All ten input reports were present and successfully read:

| Domain | Source report | Tools | Verified ready | Strictly missing / unverified |
|---|---|---:|---:|---:|
| Core Memory | [`01-core.md`](neural-tools/01-core.md) | 8 | 0 | 8 |
| Session and Context | [`02-session.md`](neural-tools/02-session.md) | 3 | 0 | 3 |
| Provenance and Sources | [`03-provenance.md`](neural-tools/03-provenance.md) | 2 | 0 | 2 |
| Analytics and Health | [`04-analytics.md`](neural-tools/04-analytics.md) | 5 | 0 | 5 |
| Cognitive Reasoning | [`05-cognitive.md`](neural-tools/05-cognitive.md) | 8 | 0 | 8 |
| Training and Import | [`06-training.md`](neural-tools/06-training.md) | 4 | 0 | 4 |
| Memory Management | [`07-management.md`](neural-tools/07-management.md) | 7 | 0 | 7 |
| Cloud Sync and Backup | [`08-sync.md`](neural-tools/08-sync.md) | 4 | 0 | 4 |
| Versioning and Transfer | [`09-versioning.md`](neural-tools/09-versioning.md) | 3 | 0 | 3 |
| Other lifecycle/reflex/graph/storage | [`10-other.md`](neural-tools/10-other.md) | 19 | 0 | 19 |
| **Total** | **ten reports** | **63** | **0** | **63** |

There are **24 partial local foundations** across the 63 rows, but all remain missing as exact parity because routing, exact schemas/state, and/or focused lifecycle tests are absent. The other **39** have no substantive native analogue. This document deliberately preserves that distinction in the inventory without converting partial foundations into completion.

### Common verified baseline and common blockers

- The current local component is a valuable, actor-isolated, project-scoped, on-device SQLite store for **explicitly approved facts**, anchors, and undirected co-occurrence. It has manual capture, bounded deterministic recall, deletion/purge, and JSON export.
- The current agent path only may inject up to three recalled approved facts before a provider call, and only when project sharing consent, a workspace, and file tools are available. General-question/JEV classification can suppress that path. This is not a callable native memory tool.
- `NativeAgentEngine` currently offers only `list_files`, `read_file`, and optionally `propose_edit`; it has no exact `nmem_*` registration or dispatcher.
- The remote NativeMCP feature is manually enabled, public-HTTPS Streamable HTTP with one-use UI approval. It excludes stdio/local servers and is not integrated into `NativeAgentEngine`. It must **not** be credited as native parity.
- The upstream Python MCP stdio process, its optional dependencies, and a manually hosted remote server are not an iPhone-native implementation. No source-code edits or XCTest execution are claimed by this synthesis.

## Critical dependency order

Implement in this order; later stages must not bypass an earlier security, storage, or test gate.

1. **Freeze the native compatibility and privacy contract.** Publish supported-versus-rejected upstream fields, establish a stable project ID boundary, version all migrations, and retain the current default of no automatic permanent capture. Resolve handler/schema discrepancies before declaring compatibility.
2. **Build a local tool boundary.** Add Codable request/result/error models, explicit tool availability policy, an allowlisted native registry, a dispatcher owned by `NativeAgentEngine`, durable `tool.selected`/`tool.completed`/`tool.failed` evidence, cancellation handling, and a scripted-provider XCTest harness. Do not delegate this boundary to the remote MCP connector.
3. **Create the common versioned graph/store substrate.** Extend project-isolated SQLite transactionally for stable IDs, typed records, tags, priority, tier, expiry/valid time, lifecycle/access metadata, typed directed edges, provenance/audit events, source registry, indexed lookup, and export/import schema versions. Enforce foreign-key and cross-project denial tests.
4. **Ship safe local reads first.** Implement deterministic read-only lookup, recall/context selection, show, source/provenance trace, stats, health, narrative, budget, and visualization only after their needed local fields exist. Every unsupported parameter must return an explicit error, not be silently ignored.
5. **Add reviewed local writes and lifecycle operations.** Route durable create/edit/evidence/session/goal/refinement operations into a pending-review queue. Add explicit confirmation, audit/undo/recovery, and atomic transaction behavior before exposing destructive, semantic, or long-lived mutations.
6. **Add cognitive, temporal, and maintenance state.** Implement hypotheses/evidence/predictions/gaps, schema evolution, conflicts, causal/time edges, lifecycle/review/tier/reflex/cache/offload state, pure Swift deterministic algorithms, fixed-clock tests, and bounded background maintenance.
7. **Add selected-file/workspace capabilities.** Training, database inspection, indexing, watching, package transfer, and imports must consume only user-granted security-scoped resources, with preview, limits, cancellation, durable progress, and no arbitrary model-provided path traversal.
8. **Add snapshot/transfer safety.** Version, diff, rollback, transplant, conflict resolution, and package import need preflight reports, atomic recovery snapshots, one-use source/destination grants, and destructive-operation confirmation.
9. **Add network features last.** Cloud sync, remote migrations, registry publish/browse, and chat backup require a separate product decision, Keychain secrets, TLS/endpoint rules, transfer consent, redacted evidence, offline/error behavior, deterministic conflict semantics, and iOS-background constraints. They are not enabled by memory-sharing consent.
10. **Promote a row only after its gate passes.** Each row below requires its own direct contract test and provider-driven terminal-cycle test. A generic agent completion test, UI behavior, local JSON export, or connector test cannot promote status.

## Automatic recall and capture: required permission model

### Automatic recall / provider disclosure

1. **On-device lookup may be local**, but automatic prompt injection or a model-visible tool response must require an explicit, revocable **per-project “share approved memory with this provider”** consent. It must identify the provider/data boundary and default to off.
2. The injected or returned set must be **bounded, project-scoped, provenance-labeled, and recorded locally** with selected IDs, policy version, timestamp, and reason. It must never include another project's data.
3. Keep **automatic recap/context** separate from a user-invoked recall tool. Context selection must be observable and reproducible, preserve a token/result budget, and be suppressed immediately when consent is revoked. Do not silently rely on workspace/file-tool/JEV conditions as the only privacy control; if retained, test and surface them as availability conditions.
4. Model-visible data should be limited to previously approved local content and the exact result needed for the request. Source references, audit actors, file paths, raw tool output, credentials, and deleted/expired content require their own minimization/redaction rules.
5. Read-only local UI use does not imply outbound sharing; tool registration itself should be policy-controlled and absent when the required consent/capability is absent.

### Automatic capture / persistent mutation

1. **No permanent automatic capture by default.** Current product behavior requires explicit approval per fact and promises not to silently capture chats, agent output, or files. Retain that baseline.
2. A future automatic extraction feature must be a **separate, project-scoped, revocable opt-in**. It may generate local candidates, but it must not persist a candidate until the user reviews the exact content, source, expiry, sensitivity/redaction result, and destination project. Batch approval must enumerate every item; no blanket approval is inferred.
3. Recall misses, private queries, tool output, model prose, watched-file changes, and inferred causal/cognitive claims must not become permanent data without the applicable review policy. Temporary offload requires a distinct retention/expiry policy and must not enter normal approved-memory export.
4. Audit stamps, verification/approval assertions, goal/boundary changes, source mutation, session persistence, review marking, and destructive actions require **separate authority**. A model-supplied actor string, existing capture approval, or sharing toggle is insufficient.
5. Hard delete, rollback, transplant, merge, remote upload, credential/config changes, notification scheduling, and external backups require foreground, one-use confirmation bound to the precise object/scope/strategy/destination. Persist an auditable receipt and offer recovery/undo where meaningful.

## Small on-device semantic fallback: Apple `NLEmbedding`

A modest local enhancement is feasible **only as an optional candidate-ranking fallback**, not as a claim of upstream neural-memory/embedding parity:

- Keep the existing deterministic token-anchor and co-occurrence retrieval as the always-available baseline. When an Apple `NLEmbedding` model is available for the query language/device, create a small, bounded candidate set from local anchors first, then score query-to-candidate text using on-device embedding similarity.
- Do not require a network model download, create a cloud embedding request, or send raw facts to an embedding service. If `NLEmbedding` is unavailable for the language or returns no usable vector, deterministically fall back to lexical/co-occurrence ranking and record the fallback reason locally.
- Limit text length, candidate count, CPU time, and returned results; continue enforcing project isolation and provider-sharing consent before any result leaves the device. Treat embeddings as derived local indexes; if persisted, version them by OS/language/model identifier and invalidate/rebuild safely after content changes.
- This option improves recall ordering only. It does **not** create typed fibers, encoder semantics, reflexes, hidden-layer APIs, graph lifecycle behavior, or any of the 63 upstream contracts. Add fixed-fixture tests for availability, deterministic fallback, isolation, and no-network behavior before enabling it.

## Feasibility boundaries for cloud-only and shell-only upstream behavior

| Category | Feasibility on iPhone | Required treatment |
|---|---|---|
| Pure local graph/query/lifecycle behavior | Generally feasible only as a Swift reimplementation with a migrated local schema and bounded computation. | Implement locally; preserve project isolation, exact contracts where claimed, approvals, and XCTest lifecycle coverage. |
| Python stdio, Python extras, shell paths, environment variables, desktop CWD assumptions | **Not directly feasible as native parity.** iOS cannot treat a Python subprocess, shell path, environment secret, or local stdio server as an embedded phone feature. | Reimplement the supported subset in Swift/Apple frameworks or mark unsupported. Do not count a remote Python host or manual MCP connector as completion. |
| Rich-document parsing, file/database training, indexing, watching | Feasible only in a restricted, user-selected capability model; continuous desktop-style watching/background work is constrained by iOS lifecycle. | Use security-scoped URLs/bookmarks, read-only access where appropriate, foreground/short background work, size/page/row limits, previews, explicit confirmation, cancellation, and no symlink/path escape. Narrow formats where native extraction is unavailable. |
| Cloud hub synchronization, remote adapters, community registry, Telegram-style transfer | Technically feasible as a **separate network product**, not as offline parity or automatic memory behavior. | Require explicit transfer consent, TLS/endpoint validation, Keychain credentials, no secret/model-log leakage, deterministic conflicts, mock-transport tests, offline/retry status, and best-effort iOS scheduling. |
| NumPy/Koopman and other optional scientific paths | Not a valid implicit iOS dependency. | Specify and reimplement a deterministic native algorithm with its own user/permission policy, or reject the action. Do not expose an undocumented handler-only action as supported parity. |

## Preserved upstream and audit caveats

- The Core batch contract has a **schema/handler mismatch** for some optional fields; choose and document a compatibility target, then test it rather than silently accepting/discarding values.
- Cognitive prediction includes a handler-only optional scientific action not advertised by the public schema. It is unsupported until separately specified and natively implemented.
- Code indexing documentation/schema advertises broad default extensions while the inspected handler defaults to Python files when extensions are omitted. Native behavior must choose one explicit, tested contract.
- Analytics health includes a handler-only deep branch; cloud/licensing and background/scheduler assumptions likewise require explicit native product decisions rather than inferred parity.
- The reports are static source audits. Existing XCTest files were inspected, not run in this Linux synthesis; the iOS checkout was already dirty in at least one audit and this task made no code changes.

## Complete 63-tool inventory and explicit release gates

**Legend:** Every row is **Missing/unverified** for exact native parity. “Partial foundation” describes adjacent local code only and does not reduce the missing count. Each numbered gate is a required, falsifiable release gate: direct contract/persistence assertions **and** a scripted `NativeAgentEngine` call that records the specified terminal lifecycle evidence.

| # | Domain | Exact tool | Strict status and available foundation | Explicit test gate required before Ready |
|---:|---|---|---|---|
| G01 | Core Memory | `nmem_remember` | **Missing** — partial single user-approved fact capture. | Assert full supported request/result metadata, no write before approval, then stable ID/typed state; a provider call must yield pending review then one approved write, `tool.completed`, `run.completed`, and `.finished`. |
| G02 | Core Memory | `nmem_remember_batch` | **Missing** — no batch primitive. | Assert max-20 validation, indexed partial success, and no writes for 21 items; an approval sheet must permit only selected items and finish with durable per-item results and `.finished`. |
| G03 | Core Memory | `nmem_recall` | **Missing** — partial local token/co-occurrence recall and preprompt injection. | Fixed graph proves depth/filter/exact/empty behavior or explicit unsupported-field errors; consented provider receives only same-project approved matches, opt-out leaks none, and both cycles terminate `.finished`. |
| G04 | Core Memory | `nmem_show` | **Missing** — partial local records/export. | Lookup by each accepted stable ID returns verbatim content, metadata, edges, and rejects foreign IDs; consented provider gets only same-project result followed by `tool.completed` and `.finished`. |
| G05 | Core Memory | `nmem_context` | **Missing** — query-match injection is not recent context. | Fixed clock proves recent/fresh/HOT/ghost/expiry/token behavior; a consented pre-provider context records selected IDs, while no-consent appends none and both exits finish. |
| G06 | Core Memory | `nmem_todo` | **Missing** — no typed todo/expiry. | Assert default priority, exact 30-day expiry, override, and close transition; approve/deny provider calls separately and require no denied write plus terminal `.finished`. |
| G07 | Core Memory | `nmem_auto` | **Missing by design** — no auto-capture path. | Deterministic analyze creates candidates only; disabled/denied processing writes nothing, per-item approval persists only selections, and the reviewed provider flow ends `.finished`. |
| G08 | Core Memory | `nmem_suggest` | **Missing** — no typed prefix/access index. | Fixture proves prefix/type/limit and idle ordering from access history; consented result stays project-scoped, opt-out shares none, and run evidence terminates `.finished`. |
| G09 | Session and Context | `nmem_session` | **Missing** — no session state/tombstone lifecycle. | Set/get/end proves merge, state, summary, retention, and inactive tombstone; provider performs set/end via native route with two completions and final `.finished`. |
| G10 | Session and Context | `nmem_eternal` | **Missing** — partial approved-fact persistence only. | Approved save/status proves typed project-context replacement, decision reason, instruction, tags/priorities, and reopen persistence; routed provider save records completion and `.finished`. |
| G11 | Session and Context | `nmem_recap` | **Missing** — partial opt-in top-three prompt injection. | Seeded eternal records prove deterministic levels/topics/budgets and opt-out; a fresh consented engine call returns local recap, survives restart, records tool evidence, and finishes. |
| G12 | Provenance and Sources | `nmem_provenance` | **Missing** — partial immutable source/provenance fields. | Trace/verify/approve proves source/audit chain and authorized append-only stamps after reopen; authorized and denied provider cases record completion/failure and a defined terminal phase. |
| G13 | Provenance and Sources | `nmem_source` | **Missing** — partial capture-time source label only. | Register/list/get/update plus linked-delete-supersede semantics prove project isolation; approved provider registration completes, while denial writes nothing and still terminates. |
| G14 | Analytics and Health | `nmem_stats` | **Missing** — partial UI fact count. | Deterministic typed graph verifies every count/distribution/hint field; consented provider receives the exact report and ordered events through `.finished`. |
| G15 | Analytics and Health | `nmem_health` | **Missing** — no diagnostics state. | Empty/degraded fixtures prove purity, grade, metrics, penalties, roadmap, and any advertised deep behavior; provider report call yields completion and `.finished`. |
| G16 | Analytics and Health | `nmem_evolution` | **Missing** — no maturation/reinforcement history. | Fixed-clock staged fibers prove all time/process metrics and deterministic top candidates; consented provider call records route/result/terminal completion. |
| G17 | Analytics and Health | `nmem_habits` | **Missing** — partial generic agent events only. | Repeated action fixture proves suggest/list/approved clear thresholds and validation; provider suggestion ends `.finished`, and denied clear makes no mutation. |
| G18 | Analytics and Health | `nmem_narrative` | **Missing** — partial recall/creation dates only. | Fixed temporal/causal graph proves validation, caps, ordering, Markdown, and no causal inference from co-occurrence; topic provider call completes and finishes. |
| G19 | Cognitive Reasoning | `nmem_hypothesize` | **Missing** — no cognitive typed state. | Approved create/list/get proves confidence clamping, active state, expiry, and no preapproval row; provider receives result ID then records `.finished`. |
| G20 | Cognitive Reasoning | `nmem_evidence` | **Missing** — no directional evidence graph. | Weighted for/against evidence proves update math, counts, edges, and only third-item auto-resolution; resolved-case failure does not mutate and provider cycle terminates. |
| G21 | Cognitive Reasoning | `nmem_predict` | **Missing** — no prediction/deadline/calibration state. | Reject malformed/past deadlines; prove linked/unlinked pending state, expiry, edge, and zero-resolution calibration; provider create finishes and unsupported hidden action rejects. |
| G22 | Cognitive Reasoning | `nmem_verify` | **Missing** — no prediction resolution state. | Correct/wrong fixture proves one-time resolution, observation edges, calibration, and linked confidence propagation; repeat fails without change and provider run reaches `.finished`. |
| G23 | Cognitive Reasoning | `nmem_cognitive` | **Missing** — no cognitive hot index. | Fixed clock verifies refresh ranking/caps/cache then summary sees refreshed data; two routed calls produce ordered completions and final `.finished`. |
| G24 | Cognitive Reasoning | `nmem_gaps` | **Missing** — no gap entity. | Every source/default priority, related-ID cap, unresolved filter, resolve/get, and invalid source are tested; provider detect/resolve changes exactly once then finishes. |
| G25 | Cognitive Reasoning | `nmem_schema` | **Missing** — no hypothesis version chain. | Evolve/history/compare proves atomic version, parent, supersede edge/reason, and invalid predecessor denial; provider flows new ID to history and exits `.finished`. |
| G26 | Cognitive Reasoning | `nmem_explain` | **Missing** — local recall `why` is insufficient. | Deterministic graph proves fuzzy candidates, shortest typed path, evidence, cap, no-path, and tie break; local-only provider result records completion and `.finished`. |
| G27 | Training and Import | `nmem_train` | **Missing** — partial local-document label/fact capture. | Approved scoped Markdown input proves deterministic chunks, hash idempotence, provenance, pin/status, and zero writes for rejection; provider call completes/finishes without arbitrary path access. |
| G28 | Training and Import | `nmem_train_db` | **Missing** — app SQLite is not schema training. | Read-only selected DB fixture proves schema counts/fingerprint/table cap and absence of sentinel row content; provider route requires capability, returns counts, and finishes. |
| G29 | Training and Import | `nmem_index` | **Missing** — partial workspace file read only. | Scoped workspace fixture proves symbols/imports/locations, exclude/escape handling, status, and explicit default-extension rule; unauthorized scan has no records and routed success finishes. |
| G30 | Training and Import | `nmem_import` | **Missing** — local export is not import. | Approved fixture proves metrics, partial failure, provenance, limit, and idempotent reimport; remote credentials stay outside evidence and denied source makes no I/O before terminal exit. |
| G31 | Memory Management | `nmem_edit` | **Missing** — partial manual capture only. | Atomic project-scoped content/type/priority/tier update, boundary invariant, and unknown-ID no-op are proven; approved routed edit records completion and `.finished`. |
| G32 | Memory Management | `nmem_forget` | **Missing** — partial manual delete/purge. | Soft expiry and hard confirmation/cascade prove isolation and reason audit; provider hard request pauses for approval, denied action changes nothing, approved continuation finishes. |
| G33 | Memory Management | `nmem_pin` | **Missing** — no pin/tier/grounding. | Max-ID validation, pin/list/unpin, HOT promotion, grounding, and isolation are proven; approved provider mutation completes and denied case remains cleanly terminal. |
| G34 | Memory Management | `nmem_consolidate` | **Missing** — no maintenance/checkpoint engine. | Fixed data proves dry-run zero writes, deterministic strategy reports, incremental checkpoint/reset, and cancellation rollback; dry-run provider call returns report and finishes. |
| G35 | Memory Management | `nmem_drift` | **Missing** — no tags/clusters/aliases. | Stable detection/list and merge/alias/dismiss scoped resolution are proven; read-only provider detect finishes, while denied semantic resolution leaves cluster intact. |
| G36 | Memory Management | `nmem_review` | **Missing** — no schedule/history. | Fixed clock proves queue ordering/limit, mark/schedule rescheduling, duplicate handling, stats, and isolation; routed read/approved mark leaves terminal evidence. |
| G37 | Memory Management | `nmem_alerts` | **Missing** — no health-pulse alert state. | Fake pulse proves create/list-seen/acknowledge/auto-resolve and cross-project denial; provider list gets local alerts, records completion, and finishes. |
| G38 | Cloud Sync and Backup | `nmem_sync` | **Missing** — partial per-project JSON export. | Two-store mock hub proves snapshot payload, seed/push/pull/full, conflict strategy, remote apply, and unsynced post-snapshot change; no-consent makes no network call, success finishes. |
| G39 | Cloud Sync and Backup | `nmem_sync_status` | **Missing** — no ledger/config/device state. | Seeded ledger/device fixture proves masked secret, counters, timestamps, strategy, online profile and offline no-request behavior; provider result contains no raw credential and finishes. |
| G40 | Cloud Sync and Backup | `nmem_sync_config` | **Missing** — no secure sync configuration. | Set/get/setup validation proves redaction, interval clamp, enabling rules, bad URL/key/strategy rejection, and mocked health behavior; approved provider management call finishes without credential evidence. |
| G41 | Cloud Sync and Backup | `nmem_telegram_backup` | **Missing** — partial local JSON share only. | Mock multipart proves one-use recipient consent, size/cancel behavior, every configured chat, partial result, and no token in logs/export; no-consent sends nothing and approved provider flow finishes. |
| G42 | Versioning and Transfer | `nmem_version` | **Missing** — partial project JSON export. | Snapshot/list/diff/confirmed rollback proves whole-graph restoration, hash/version records, and recovery on invalid snapshot; provider create/list and approved rollback use no remote call and finish. |
| G43 | Versioning and Transfer | `nmem_transplant` | **Missing** — partial user export/share. | Source/destination grant fixture proves filters, referenced subgraph, deterministic strategy, source unchanged, report/provenance, and rollback on import failure; routed transfer finishes. |
| G44 | Versioning and Transfer | `nmem_conflicts` | **Missing** — SQL uniqueness is not semantic conflict state. | Check has zero writes; list and each confirmed resolution prove contradiction edge/lifecycle outcomes and project isolation; provider check/approved resolve records exact terminal evidence. |
| G45 | Other lifecycle/reflex/graph/storage | `nmem_reflex` | **Missing** — no reflex state. | Pin/unpin/list proves recall priority and conflict policy; approved provider pin persists, a later opted-in run observes it, and both runs finish. |
| G46 | Other lifecycle/reflex/graph/storage | `nmem_visualize` | **Missing** — no chart generator. | Numeric fixture produces requested chart spec/Markdown with exact provenance and nonnumeric fallback; serialized provider result records completion and `.finished`. |
| G47 | Other lifecycle/reflex/graph/storage | `nmem_watch` | **Missing** — transient folder selection is not monitoring. | Authorized fake bookmark change makes pending proposal only, approval controls persistence, and stop prevents next observation; scan provider path shares no raw file data and terminates. |
| G48 | Other lifecycle/reflex/graph/storage | `nmem_surface` | **Missing** — partial local export only. | Deterministic surface bytes/caps/invalidation prove cache behavior; consented cycle loads recorded surface, consent-off injects none, and both complete. |
| G49 | Other lifecycle/reflex/graph/storage | `nmem_tool_stats` | **Missing** — partial generic run events. | Seeded dated outcomes prove aggregate/day grouping and meta-query exclusion; scripted success/failure produce correct post-run stats and terminal phase. |
| G50 | Other lifecycle/reflex/graph/storage | `nmem_lifecycle` | **Missing** — no compression/freeze/expiry state. | Freeze/thaw/compress/recover fixture proves byte-identical recovery and no unwanted expiry; routed action records defined success/failure terminal evidence. |
| G51 | Other lifecycle/reflex/graph/storage | `nmem_refine` | **Missing** — immutable facts are not instructions/workflows. | Two approved revisions prove version/history/failure-mode dedupe/trigger cap; provider proposal remains pending until approval and later approved context/run finishes. |
| G52 | Other lifecycle/reflex/graph/storage | `nmem_report_outcome` | **Missing** — partial generic terminal events. | Three outcomes prove instruction-scoped counts/rate/deduped failure detail; only actual terminal outcome records success and cancelled/failed runs do not, then finish deterministically. |
| G53 | Other lifecycle/reflex/graph/storage | `nmem_budget` | **Missing** — fixed top-three recall is not budgeting. | Fixed estimator proves estimate/analyze ordering and zero mutation; routed estimate constrains selected context to max tokens and terminal event is recorded. |
| G54 | Other lifecycle/reflex/graph/storage | `nmem_tier` | **Missing** — no tier/history. | Evaluate proves zero writes; approved apply proves eligible changes/history and manual/critical protection; denied apply stays unchanged and route completes. |
| G55 | Other lifecycle/reflex/graph/storage | `nmem_boundaries` | **Missing** — no typed safety boundary. | Domain/global fixtures prove filter/count/protected priority; provider sees only approved project boundaries and cannot create/alter one via ordinary text, ending with denial evidence. |
| G56 | Other lifecycle/reflex/graph/storage | `nmem_milestone` | **Missing** — no milestone ledger. | Fixed thresholds prove exactly one first crossing, no duplicate on repeat, and correct next progress; tool check records one event then terminal completion. |
| G57 | Other lifecycle/reflex/graph/storage | `nmem_store` | **Missing** — partial JSON export and confirmed purge. | Selected-project export, invalid/scanner-rejected package no-op, and confirmed valid import/delete are proven; provider may preview only and denied import/delete/publish still ends. |
| G58 | Other lifecycle/reflex/graph/storage | `nmem_goal` | **Missing** — no goals/subgoal edges. | Parent/child, state/priority, and transparent deterministic recall bias are proven; only approved activation affects context, silent provider creation is denied, and run finishes. |
| G59 | Other lifecycle/reflex/graph/storage | `nmem_causal` | **Missing** — partial generic graph traversal only. | Directed causal/temporal fixture proves traces, sequences, time filter, depth guard, and excludes co-occurrence; provider gets provenance path and terminal completion. |
| G60 | Other lifecycle/reflex/graph/storage | `nmem_cache` | **Missing** — recall recomputes; no activation cache. | Save/reopen/load hit metrics and mutation invalidation prove versioned cache safety; recreated engine records cache event and completes on hit/miss. |
| G61 | Other lifecycle/reflex/graph/storage | `nmem_offload` | **Missing** — no ephemeral redacted result store. | Secret fixture proves redaction, cap, reference, savings, isolated expiry cleanup, and exclusion from approved export; large tool result returns summary/ref and run finishes without permanent fact write. |
| G62 | Other lifecycle/reflex/graph/storage | `nmem_inflate` | **Missing** — no offload reference model. | Live same-project reference returns only permitted redacted payload; foreign/expired/ordinary IDs leak nothing; second provider call completes and cross-project call fails terminally. |
| G63 | Other lifecycle/reflex/graph/storage | `nmem_situation` | **Missing** — partial generic run evidence only. | Fixed session/decision/blocker fixture proves top-three ordering, unresolved filtering, suggestion, and zero writes; routed snapshot honors consent and ends `.finished`. |

## Promotion checklist for every inventory row

A status may change from **Missing/unverified** to **Ready** only when a review can point to all of the following for that exact row:

1. Versioned local Swift schema/handler with explicit input, output, error, unsupported-field, and project-isolation behavior.
2. Exact allowlisted native tool definition and `NativeAgentEngine` dispatcher branch; no remote connector or hosted Python substitution.
3. Appropriate consent/capability/confirmation policy and durable redacted audit event; all denied/revoked cases have zero unauthorized side effects.
4. Direct XCTest with deterministic store/clock/transport fixtures, including malformed input, isolation, cancellation, and persistence/rollback where applicable.
5. Scripted provider lifecycle XCTest proving offer → selection → result/failure → final provider response → durable `run.completed`/defined terminal evidence and `.finished` (or explicit `.failed`/`.cancelled` where expected), with a finite stream.
6. For networked rows, mock-transport tests proving no unconsented network traffic and no credential, raw token, or sensitive content leakage into model messages, run evidence, exports, or logs.

Until all of those conditions hold, the accurate implementation claim remains **0 verified / 63 missing native-parity tools**.
