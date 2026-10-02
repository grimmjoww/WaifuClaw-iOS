import Foundation
import XCTest
@testable import WaifuClaw

final class NativeNeuralMemoryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testApprovedFactPersistsAfterReopening() async throws {
        let databaseURL = try makeDatabaseURL()
        let firstStore = try LocalNeuralMemoryStore(databaseURL: databaseURL)
        let expected = try await firstStore.capture(
            request(
                projectID: "ios-app",
                fact: "The app uses SQLite for approved local memory.",
                source: LocalMemorySource(
                    kind: .manualNote,
                    label: "Memory editor",
                    reference: "note-42"
                ),
                provenance: LocalMemoryProvenance(
                    capturedBy: "user",
                    sourceRecordID: "note-42",
                    approvalNote: "Keep this architecture decision."
                )
            ),
            approval: .userApproved
        )

        let reopenedStore = try LocalNeuralMemoryStore(databaseURL: databaseURL)
        let saved = try await reopenedStore.memories(in: "ios-app")

        XCTAssertEqual(saved.count, 1)
        let loaded = try XCTUnwrap(saved.first)
        XCTAssertEqual(loaded.id, expected.id)
        XCTAssertEqual(loaded.projectID, expected.projectID)
        XCTAssertEqual(loaded.content, expected.content)
        XCTAssertEqual(loaded.source, expected.source)
        XCTAssertEqual(loaded.provenance, expected.provenance)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, expected.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testProjectsAreIsolatedForRecallAndExport() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let iosFact = try await store.capture(
            request(projectID: "ios", fact: "Korra prefers jasmine tea."),
            approval: .userApproved
        )
        let androidFact = try await store.capture(
            request(projectID: "android", fact: "Korra prefers jasmine tea."),
            approval: .userApproved
        )

        let iosResults = try await store.recall(projectID: "ios", query: "jasmine tea")
        let androidResults = try await store.recall(projectID: "android", query: "jasmine tea")
        let iosExport = try await store.exportProject("ios", exportedAt: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(iosResults.map(\.id), [iosFact.id])
        XCTAssertEqual(androidResults.map(\.id), [androidFact.id])
        XCTAssertEqual(iosExport.projectID, "ios")
        XCTAssertEqual(iosExport.facts.map(\.id), [iosFact.id])
        XCTAssertFalse(iosExport.anchors.isEmpty)
        XCTAssertTrue(iosExport.synapses.allSatisfy { $0.projectID == "ios" })
    }

    func testDirectAnchorMatchRanksAheadOfCooccurrenceSpread() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let direct = try await store.capture(
            request(projectID: "avatar", fact: "Korra serves jasmine tea after practice."),
            approval: .userApproved
        )
        let related = try await store.capture(
            request(projectID: "avatar", fact: "Korra trains before dawn."),
            approval: .userApproved
        )

        let results = try await store.recall(
            projectID: "avatar",
            query: "jasmine tea",
            options: LocalMemoryRecallOptions(maximumHops: 2, decay: 0.55, minimumScore: 0.01, limit: 10)
        )
        let top = try XCTUnwrap(results.first)
        let spread = try XCTUnwrap(results.first(where: { $0.id == related.id }))

        XCTAssertEqual(top.id, direct.id)
        XCTAssertEqual(top.storedFact, direct.content)
        XCTAssertEqual(top.source, direct.source)
        XCTAssertEqual(top.hopCount, 0)
        XCTAssertTrue(top.why.hasPrefix("Direct anchor match:"))
        XCTAssertGreaterThan(top.score, spread.score)
        XCTAssertEqual(spread.hopCount, 1)
        XCTAssertTrue(spread.why.contains("Spreading activation hop 1"))
    }

    func testDeleteOneMemoryThenPurgeOnlyItsProject() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let first = try await store.capture(
            request(projectID: "one", fact: "Aang studies airbending forms."),
            approval: .userApproved
        )
        let second = try await store.capture(
            request(projectID: "one", fact: "Aang studies glider repairs."),
            approval: .userApproved
        )
        let otherProject = try await store.capture(
            request(projectID: "two", fact: "Aang studies airbending forms."),
            approval: .userApproved
        )

        try await store.deleteMemory(id: first.id, projectID: "one")
        let afterOneDeletion = try await store.memories(in: "one")
        XCTAssertEqual(afterOneDeletion.map(\.id), [second.id])
        do {
            try await store.deleteMemory(id: first.id, projectID: "one")
            XCTFail("Deleting the same memory twice should report that it is absent.")
        } catch let error as LocalNeuralMemoryError {
            XCTAssertEqual(error, .memoryNotFound(id: first.id, projectID: "one"))
        }

        try await store.purgeProject("one")
        let purgedProjectFacts = try await store.memories(in: "one")
        let survivingProjectFacts = try await store.memories(in: "two")
        let purgedExport = try await store.exportProject("one")
        XCTAssertTrue(purgedProjectFacts.isEmpty)
        XCTAssertEqual(survivingProjectFacts.map(\.id), [otherProject.id])
        XCTAssertTrue(purgedExport.anchors.isEmpty)
        XCTAssertTrue(purgedExport.synapses.isEmpty)
    }

    func testRecallAndJSONExportPreserveSourceAndProvenance() async throws {
        let store = try LocalNeuralMemoryStore(databaseURL: try makeDatabaseURL())
        let source = LocalMemorySource(
            kind: .conversation,
            label: "Conversation #7",
            reference: "message-9"
        )
        let provenance = LocalMemoryProvenance(
            capturedBy: "conversation-ui",
            sourceRecordID: "message-9",
            approvalNote: "Approved in the save-memory sheet."
        )
        let fact = try await store.capture(
            request(
                projectID: "provenance",
                fact: "Momo is assigned to the navigation test plan.",
                source: source,
                provenance: provenance
            ),
            approval: .userApproved
        )

        let recallResults = try await store.recall(projectID: "provenance", query: "navigation test")
        let recalled = try XCTUnwrap(recallResults.first)
        let json = try await store.exportJSON(
            forProject: "provenance",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(LocalMemoryExport.self, from: json)

        XCTAssertEqual(recalled.id, fact.id)
        XCTAssertEqual(recalled.source, source)
        XCTAssertEqual(recalled.fact.provenance, provenance)
        XCTAssertEqual(exported.projectID, "provenance")
        XCTAssertEqual(exported.facts.map(\.id), [fact.id])
        XCTAssertEqual(exported.facts.first?.source, source)
        XCTAssertEqual(exported.facts.first?.provenance, provenance)
        let exportedFact = try XCTUnwrap(exported.facts.first)
        XCTAssertEqual(exportedFact.createdAt.timeIntervalSince1970, fact.createdAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("Conversation #7"))
    }

    private func request(
        projectID: String,
        fact: String,
        source: LocalMemorySource = LocalMemorySource(kind: .manualNote, label: "Memory editor"),
        provenance: LocalMemoryProvenance = LocalMemoryProvenance(capturedBy: "user")
    ) -> LocalMemoryCaptureRequest {
        LocalMemoryCaptureRequest(
            projectID: projectID,
            fact: fact,
            source: source,
            provenance: provenance
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("LocalNeuralMemory.sqlite", isDirectory: false)
    }
}
