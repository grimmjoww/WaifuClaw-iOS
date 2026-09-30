# Neural-memory source mapping and attribution

## Upstream reviewed

This local iPhone implementation was designed after selectively reading the core concepts in [`grimmjoww/neural-memory`](https://github.com/grimmjoww/neural-memory), checkout **`2015cb9b0973a6fe14a3bc547c932d64d6ced203`**:

- `src/neural_memory/core/neuron.py`
- `src/neural_memory/core/synapse.py`
- `src/neural_memory/engine/activation.py`
- `src/neural_memory/engine/encoder.py`
- `tests/unit/test_activation.py`
- `tests/storage/postgres/test_postgres_synapses.py`

The reviewed upstream repository is licensed under the **MIT License** (copyright © 2024 NeuralMemory Contributors). Its full notice is in the selected upstream checkout's `LICENSE` and the upstream repository's [`LICENSE`](https://github.com/grimmjoww/neural-memory/blob/2015cb9b0973a6fe14a3bc547c932d64d6ced203/LICENSE). The MIT license requires that its copyright and permission notice accompany copies or substantial portions of the Software.

This is a new, deliberately small Swift implementation using Foundation and SQLite3; it does not copy the upstream Python implementation or claim to be a full port.

## Concept mapping

| Upstream concept | Source reviewed | iPhone implementation | Intentional boundary |
|---|---|---|---|
| Immutable memory **Neuron** with ID, content, metadata, and timestamp; activation state is conceptually separate | `core/neuron.py` | `LocalMemoryFact` is an immutable **fact-neuron** with UUID, project ID, content, source, provenance, and `createdAt`. `anchor_neurons` hold deterministic keyword/token nodes. | No upstream neuron taxonomy, lifecycle/reflex state, confidence, validity windows, or persistent activation-state model. |
| Bounded `Synapse` weights, bidirectional associative links, and co-occurrence relationship | `core/synapse.py` | `fact_anchor_synapses` form fact → anchor edges; `cooccurrence_synapses` are canonical, undirected fact-pair links. Weight is cosine-style shared-anchor overlap and is constrained to `0...1`. | Only two edge types are implemented. There are no semantic/causal/audit/reinforcement types, decay persistence, or Hebbian learning. |
| Spreading activation: start from anchors, multiply by decay and synapse weight, threshold low signal, constrain hops | `engine/activation.py`; `tests/unit/test_activation.py` | Recall starts with exact query-anchor matches at hop 0, then uses `next = current × decay × coOccurrenceWeight`. The implementation preserves only stronger routes, clamps scores, clamps hops to **0...4**, and limits graph expansion to **1...1,024** nodes (default 256). `why`, matched anchors, hops, and score are returned. | No role multipliers, activation cache, refractory behavior, frequency boosts, diminishing-return heuristics, fibers, or multi-anchor intersection fusion. |
| Encoder pipeline creates extracted neurons, anchor, synapses, co-occurrence, and optional enrichment | `engine/encoder.py` | `capture(_:approval:)` atomically stores one user-approved fact, derives deterministic normalized token anchors, and writes co-occurrence edges. | No auto-tagging, NER, relation extraction, emotion/time extraction, conflict detection, semantic linking, LLM calls, or asynchronous enrichment. |
| Storage CRUD, neighbor traversal, and deletion behavior | `tests/storage/postgres/test_postgres_synapses.py` | SQLite foreign keys, composite project-scoped foreign keys, WAL, bounded transactions, schema version checking, one-memory deletion, project purge, and JSON export. | iOS-local SQLite only; not the upstream's storage adapter matrix. |

## What this component actually guarantees

- **User-approved writes only.** Production writes exist only through `capture(_:approval:)`, whose required `approval: .userApproved` argument makes a user-confirmed save explicit. There is no chat, file, or agent auto-capture API.
- **Project isolation.** Every node, synapse, foreign-key relationship, recall query, deletion, and export carries `project_id`. Composite foreign keys prevent a fact in one project from referencing an anchor or fact in another.
- **On-device only.** The component uses only `Foundation` and `SQLite3`; it contains no remote client, endpoint, upload, embedding-provider, or credential/key storage.
- **Bounded deterministic behavior.** Project capacity defaults to 2,000 facts; each fact has at most 24 anchors; scores and weights are `0...1`; graph traversal has hard caps and deterministic tie-breaking.
- **Auditable recall.** A `LocalMemoryRecallResult` returns the immutable fact, source, score, matched anchors, hop count, and a displayable `why` explanation.

## Parent UI / local-agent integration API

The host must show an approval affordance before calling the write method. Keep any conversation or agent proposal outside this store until the user confirms it.

```swift
let memoryStore = try LocalNeuralMemoryStore()

let request = LocalMemoryCaptureRequest(
    projectID: selectedProjectID,
    fact: approvedFactText,
    source: LocalMemorySource(
        kind: .agentProposal,
        label: "Native agent proposal",
        reference: proposalMessageID
    ),
    provenance: LocalMemoryProvenance(
        capturedBy: "memory-save-sheet",
        sourceRecordID: proposalMessageID,
        approvalNote: userEnteredReason
    )
)

// Invoke only after the user approves this exact fact in the UI.
let saved = try await memoryStore.capture(request, approval: .userApproved)
let results = try await memoryStore.recall(
    projectID: saved.projectID,
    query: agentOrUserQuery
)

try await memoryStore.deleteMemory(id: saved.id, projectID: saved.projectID)
try await memoryStore.purgeProject(saved.projectID) // only after a destructive-action confirmation
let localJSON = try await memoryStore.exportJSON(forProject: saved.projectID)
```

## Explicit limitations — no unverifiable “Pro” claim

This is **not** an upstream NeuralMemory Pro edition or a complete 400-module Python port. In particular it does **not** implement hybrid/vector/embedding recall, HNSW, external models, cross-project search, cloud sync, Pro storage adapters, encryption features, workflow tooling, cognitive layers, fibers, semantic relation extraction, or an upstream compatibility protocol.

Recall is a transparent **exact normalized-token + bounded weighted co-occurrence graph**. It is useful for on-device approved facts, but it does not understand paraphrases that share no token anchors. Any future embedding or hybrid layer should be separately designed, explicitly disclosed, kept project-scoped, and tested; it must not be labeled as implemented by this component today.
