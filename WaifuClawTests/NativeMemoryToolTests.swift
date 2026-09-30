import Foundation
import XCTest
@testable import WaifuClaw

final class NativeMemoryToolTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRegistryHasAuditedVocabularyButOffersOnlyConsentGatedReadOnlySubset() async throws {
        let projectID = selectedProjectID()
        let allowed = access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)
        let definitions = NativeMemoryToolRegistry.definitions(for: allowed)

        XCTAssertEqual(NativeMemoryToolRegistry.upstreamToolCount, 63)
        XCTAssertEqual(NativeMemoryUpstreamTool.allCases.count, 63)
        XCTAssertEqual(definitions.map(\.name), ["nmem_recall", "nmem_show"])
        XCTAssertEqual(NativeMemoryToolRegistry.maximumRecallResults, 12)
        XCTAssertEqual(NativeMemoryToolRegistry.maximumShowSynapses, 64)
        for definition in definitions {
            let schema = try object(from: String(decoding: definition.parametersJSON, as: UTF8.self))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }

        let consentDenied = access(selectedProjectID: projectID, requestedProjectID: projectID, consent: false)
        let missingProject = access(selectedProjectID: nil, requestedProjectID: nil, consent: true)
        let mismatchedProject = access(
            selectedProjectID: projectID,
            requestedProjectID: String(repeating: "b", count: 64),
            consent: true
        )
        XCTAssertTrue(NativeMemoryToolRegistry.definitions(for: consentDenied).isEmpty)
        XCTAssertTrue(NativeMemoryToolRegistry.definitions(for: missingProject).isEmpty)
        XCTAssertTrue(NativeMemoryToolRegistry.definitions(for: mismatchedProject).isEmpty)
    }

    func testAllowedRecallUsesRealSQLiteHasStableOrderAndBoundedResults() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        for index in 0..<14 {
            _ = try await capture(
                store: store,
                projectID: projectID,
                fact: "Jasmine tea fixture memory \(index) provides a distinct detail."
            )
        }
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let allowed = access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)

        let first = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: #"{"query":"jasmine tea","depth":0}"#,
            access: allowed
        )
        let second = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: #"{"query":"jasmine tea","depth":0}"#,
            access: allowed
        )
        let firstPayload = try object(from: first.responseJSON)
        let secondPayload = try object(from: second.responseJSON)
        let firstMemories = try memories(from: firstPayload)
        let secondMemories = try memories(from: secondPayload)
        let firstIDs = firstMemories.compactMap { $0["memory_id"] as? String }
        let secondIDs = secondMemories.compactMap { $0["memory_id"] as? String }

        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(first.effects.map(\.kind), ["tool.selected", "tool.completed"])
        XCTAssertEqual(firstPayload["retrieval"] as? String, "local_token_anchor_cooccurrence")
        XCTAssertEqual(firstPayload["depth"] as? Int, 0)
        XCTAssertEqual(firstPayload["maximum_results"] as? Int, 12)
        XCTAssertEqual(firstPayload["result_count"] as? Int, 12)
        XCTAssertEqual(firstMemories.count, 12)
        XCTAssertEqual(firstIDs, secondIDs, "An unchanged SQLite fixture must produce stable recall order.")
        XCTAssertTrue(firstMemories.allSatisfy { ($0["content"] as? String)?.contains("Jasmine tea") == true })

        let factsAfterRead = try await store.memories(in: projectID)
        XCTAssertEqual(factsAfterRead.count, 14, "Read-only tools must not create or mutate local facts.")
    }

    func testShowReturnsOnlySelectedProjectFactAndBoundedCooccurrenceEdges() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        let first = try await capture(
            store: store,
            projectID: projectID,
            fact: "Korra keeps jasmine tea in the project kitchen.",
            source: LocalMemorySource(
                kind: .manualNote,
                label: "Approved kitchen note",
                reference: "private-reference-never-for-model"
            ),
            provenance: LocalMemoryProvenance(
                capturedBy: "private-actor-never-for-model",
                sourceRecordID: "private-source-record-never-for-model",
                approvalNote: "private-approval-never-for-model"
            )
        )
        _ = try await capture(
            store: store,
            projectID: projectID,
            fact: "Korra serves jasmine tea after training in the project kitchen."
        )
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let requestJSON = try argumentsJSON(["memory_id": first.id.uuidString])
        let shown = await dispatcher.dispatch(
            name: "nmem_show",
            argumentsJSON: requestJSON,
            access: access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)
        )
        let payload = try object(from: shown.responseJSON)
        let source = try XCTUnwrap(payload["source"] as? [String: Any])
        let synapses = payload["synapses"] as? [[String: Any]] ?? []

        XCTAssertTrue(shown.succeeded)
        XCTAssertEqual(payload["memory_id"] as? String, first.id.uuidString)
        XCTAssertEqual(payload["content"] as? String, first.content)
        XCTAssertEqual(source["kind"] as? String, LocalMemorySourceKind.manualNote.rawValue)
        XCTAssertEqual(payload["synapse_count"] as? Int, 1)
        XCTAssertFalse(payload["synapses_truncated"] as? Bool ?? true)
        XCTAssertEqual(synapses.count, 1)
        XCTAssertFalse(shown.responseJSON.contains("Approved kitchen note"))
        XCTAssertFalse(shown.responseJSON.contains("private-reference-never-for-model"))
        XCTAssertFalse(shown.responseJSON.contains("private-actor-never-for-model"))
        XCTAssertFalse(shown.responseJSON.contains("private-source-record-never-for-model"))
        XCTAssertFalse(shown.responseJSON.contains("private-approval-never-for-model"))
    }

    func testConsentNoSelectionAndRequestedProjectMismatchDenyWithoutDisclosure() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        _ = try await capture(
            store: store,
            projectID: projectID,
            fact: "Consent-protected local secret for the selected project."
        )
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let request = #"{"query":"consent protected"}"#

        let noConsent = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: request,
            access: access(selectedProjectID: projectID, requestedProjectID: projectID, consent: false)
        )
        let noSelection = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: request,
            access: access(selectedProjectID: nil, requestedProjectID: nil, consent: true)
        )
        let mismatch = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: request,
            access: access(
                selectedProjectID: projectID,
                requestedProjectID: String(repeating: "c", count: 64),
                consent: true
            )
        )

        XCTAssertEqual(try errorCode(from: noConsent.responseJSON), "consent_not_granted")
        XCTAssertEqual(try errorCode(from: noSelection.responseJSON), "project_not_selected")
        XCTAssertEqual(try errorCode(from: mismatch.responseJSON), "project_mismatch")
        for outcome in [noConsent, noSelection, mismatch] {
            XCTAssertFalse(outcome.succeeded)
            XCTAssertEqual(outcome.effects.map(\.kind), ["tool.selected", "tool.failed"])
            XCTAssertFalse(outcome.responseJSON.contains("Consent-protected local secret"))
        }
        let savedFacts = try await store.memories(in: projectID)
        XCTAssertEqual(savedFacts.count, 1)
    }

    func testInvalidArgumentsAndEveryUnsupportedUpstreamRecallFieldFailExplicitly() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let allowed = access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)
        let upstreamUnsupportedFields = [
            "max_tokens", "min_confidence", "valid_at", "include_conflicts", "warn_expiry_days",
            "brains", "min_trust", "tags", "tag_mode", "mode", "include_citations",
            "recall_token_budget", "prefer_recent", "permanent_only", "clean_for_prompt",
            "show_provenance", "include_status", "compact", "tier", "domain", "as_of",
            "simhash_threshold", "min_arousal", "valence", "layer", "exclude_reflexes",
            "include_paths", "token_budget"
        ]

        for field in upstreamUnsupportedFields {
            let json = try argumentsJSON(["query": "jasmine", field: true])
            let outcome = await dispatcher.dispatch(
                name: "nmem_recall",
                argumentsJSON: json,
                access: allowed
            )
            let payload = try object(from: outcome.responseJSON)
            let error = try XCTUnwrap(payload["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "unsupported_field", "\(field) must not be silently ignored.")
            XCTAssertEqual(error["fields"] as? [String], [field])
        }

        let invalidDepth = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: #"{"query":"jasmine","depth":4}"#,
            access: allowed
        )
        let malformed = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: "not-json",
            access: allowed
        )
        let showWithInjectedCompact = await dispatcher.dispatch(
            name: "nmem_show",
            argumentsJSON: #"{"memory_id":"00000000-0000-0000-0000-000000000000","compact":true}"#,
            access: allowed
        )
        let showWithInjectedTokenBudget = await dispatcher.dispatch(
            name: "nmem_show",
            argumentsJSON: #"{"memory_id":"00000000-0000-0000-0000-000000000000","token_budget":50}"#,
            access: allowed
        )
        let unimplementedUpstreamTool = await dispatcher.dispatch(
            name: "nmem_remember",
            argumentsJSON: #"{"content":"This must never be written by the native tool dispatcher."}"#,
            access: allowed
        )

        XCTAssertEqual(try errorCode(from: invalidDepth.responseJSON), "invalid_field")
        XCTAssertEqual(try errorCode(from: malformed.responseJSON), "invalid_json")
        XCTAssertEqual(try errorCode(from: showWithInjectedCompact.responseJSON), "unsupported_field")
        XCTAssertEqual(try errorCode(from: showWithInjectedTokenBudget.responseJSON), "unsupported_field")
        XCTAssertEqual(try errorCode(from: unimplementedUpstreamTool.responseJSON), "unsupported_tool")
    }

    func testInvalidAndForeignShowIDsDoNotRevealOtherProjectData() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let selectedID = selectedProjectID()
        let foreignID = String(repeating: "b", count: 64)
        let foreignFact = try await capture(
            store: store,
            projectID: foreignID,
            fact: "Foreign project data must never be revealed by nmem_show."
        )
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let allowed = access(selectedProjectID: selectedID, requestedProjectID: selectedID, consent: true)

        let invalid = await dispatcher.dispatch(
            name: "nmem_show",
            argumentsJSON: #"{"memory_id":"not-a-local-uuid"}"#,
            access: allowed
        )
        let foreign = await dispatcher.dispatch(
            name: "nmem_show",
            argumentsJSON: try argumentsJSON(["memory_id": foreignFact.id.uuidString]),
            access: allowed
        )

        XCTAssertEqual(try errorCode(from: invalid.responseJSON), "invalid_memory_id")
        XCTAssertEqual(try errorCode(from: foreign.responseJSON), "memory_not_found")
        XCTAssertFalse(foreign.responseJSON.contains(foreignFact.content))
        XCTAssertFalse(foreign.responseJSON.contains(foreignFact.id.uuidString))
        let selectedFacts = try await store.memories(in: selectedID)
        let foreignFacts = try await store.memories(in: foreignID)
        XCTAssertEqual(selectedFacts.count, 0)
        XCTAssertEqual(foreignFacts.map(\.id), [foreignFact.id])
    }

    func testCancellationReturnsExplicitFailureWithoutAReadResult() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        _ = try await capture(store: store, projectID: projectID, fact: "Cancelled reads must reveal nothing.")
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        let gate = NativeMemoryToolCancellationGate()
        let allowed = access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)
        let task = Task { () -> NativeMemoryToolDispatchResult in
            await gate.wait()
            return await dispatcher.dispatch(
                name: "nmem_recall",
                argumentsJSON: #"{"query":"cancelled reads"}"#,
                access: allowed
            )
        }
        await Task.yield()
        task.cancel()
        await gate.open()
        let outcome = await task.value

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(try errorCode(from: outcome.responseJSON), "cancelled")
        XCTAssertEqual(outcome.effects.map(\.kind), ["tool.selected", "tool.failed"])
        XCTAssertFalse(outcome.responseJSON.contains("Cancelled reads must reveal nothing."))
    }

    func testReadOnlyDispatchMakesNoNetworkRequest() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let projectID = selectedProjectID()
        _ = try await capture(store: store, projectID: projectID, fact: "No network is needed for local recall.")
        let dispatcher = NativeMemoryToolDispatcher(memoryStore: store)
        NativeMemoryToolNetworkTripwire.reset()
        guard URLProtocol.registerClass(NativeMemoryToolNetworkTripwire.self) else {
            throw XCTSkip("URLProtocol registration is unavailable on this test host.")
        }
        defer { URLProtocol.unregisterClass(NativeMemoryToolNetworkTripwire.self) }

        let outcome = await dispatcher.dispatch(
            name: "nmem_recall",
            argumentsJSON: #"{"query":"network local recall"}"#,
            access: access(selectedProjectID: projectID, requestedProjectID: projectID, consent: true)
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(NativeMemoryToolNetworkTripwire.requestCount, 0)
        let savedFacts = try await store.memories(in: projectID)
        XCTAssertEqual(savedFacts.count, 1)
    }

    private func selectedProjectID() -> String {
        String(repeating: "a", count: 64)
    }

    private func access(
        selectedProjectID: String?,
        requestedProjectID: String?,
        consent: Bool
    ) -> NativeMemoryToolAccessContext {
        NativeMemoryToolAccessContext(
            selectedProjectID: selectedProjectID,
            requestedProjectID: requestedProjectID,
            hasModelSharingConsent: consent
        )
    }

    private func capture(
        store: LocalNeuralMemoryStore,
        projectID: String,
        fact: String,
        source: LocalMemorySource = LocalMemorySource(kind: .manualNote, label: "Fixture note"),
        provenance: LocalMemoryProvenance = LocalMemoryProvenance(capturedBy: "fixture-user")
    ) async throws -> LocalMemoryFact {
        try await store.capture(
            LocalMemoryCaptureRequest(
                projectID: projectID,
                fact: fact,
                source: source,
                provenance: provenance
            ),
            approval: .userApproved
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("memory.sqlite", isDirectory: false)
    }

    private func object(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "NativeMemoryToolTests", code: 1)
        }
        return object
    }

    private func memories(from payload: [String: Any]) throws -> [[String: Any]] {
        guard let memories = payload["memories"] as? [[String: Any]] else {
            throw NSError(domain: "NativeMemoryToolTests", code: 2)
        }
        return memories
    }

    private func errorCode(from json: String) throws -> String {
        let payload = try object(from: json)
        guard let error = payload["error"] as? [String: Any],
              let code = error["code"] as? String
        else {
            throw NSError(domain: "NativeMemoryToolTests", code: 3)
        }
        return code
    }

    private func argumentsJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "NativeMemoryToolTests", code: 4)
        }
        return json
    }
}

private actor NativeMemoryToolCancellationGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private final class NativeMemoryToolNetworkTripwire: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        requests = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
