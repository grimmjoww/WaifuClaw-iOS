import Foundation
import XCTest
@testable import WaifuClaw

final class NativeMemoryAutomaticLifecycleTests: XCTestCase {
    private let firstProject = String(repeating: "a", count: 64)
    private let secondProject = String(repeating: "b", count: 64)
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testOptOutLeavesFinishedRunOutOfQueueAndGraph() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optOut(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )

        let result = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )

        let pendingRecords = try await environment.queue.pendingRecords(in: firstProject)
        let graphFacts = try await environment.memoryStore.memories(in: firstProject)

        XCTAssertEqual(result.outcome, .skipped(reason: .automaticCaptureOptedOut))
        XCTAssertTrue(pendingRecords.isEmpty)
        XCTAssertTrue(graphFacts.isEmpty)
    }

    func testFinishedPersistedRunCreatesUnverifiedPendingCandidate() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )

        let result = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let pendingRecords = try await environment.queue.pendingRecords(in: firstProject)
        let record = try XCTUnwrap(pendingRecords.first)
        let graphFacts = try await environment.memoryStore.memories(in: firstProject)

        XCTAssertEqual(result.outcome, .enqueued)
        XCTAssertEqual(result.candidateIDs, [record.id])
        XCTAssertEqual(record.state, .pending)
        XCTAssertEqual(record.candidate.verification, .unverifiedModelStatement)
        XCTAssertEqual(record.candidate.provenance.source, .finishedNativeAgentRun)
        XCTAssertEqual(record.candidate.provenance.projectID, firstProject)
        XCTAssertEqual(record.candidate.provenance.runID, evidence.runID)
        XCTAssertEqual(record.candidate.provenance.conversationID, evidence.conversationID)
        XCTAssertEqual(record.candidate.provenance.assistantMessageID, evidence.assistantMessageID)
        XCTAssertEqual(record.candidate.provenance.terminalPhase, .finished)
        XCTAssertTrue(graphFacts.isEmpty)
    }

    func testSameRunIsIdempotentByExactCandidateID() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )

        let first = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let second = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let records = try await environment.queue.pendingRecords(in: firstProject)

        XCTAssertEqual(first.outcome, .enqueued)
        XCTAssertEqual(second.outcome, .alreadyQueued)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "\(evidence.runID.uuidString.lowercased()):1")
        XCTAssertEqual(first.candidateIDs, second.candidateIDs)
    }

    func testExplicitPersistedAssistantMessageIDAvoidsTimestampInference() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let conversation = try await environment.runStore.createConversation(title: "Ambiguous")
        let run = try await environment.runStore.createRun(conversationID: conversation.id)
        let selectedAssistantMessage = try await environment.runStore.appendMessage(
            conversationID: conversation.id,
            role: .assistant,
            content: "We decided to use SQLite for local project memory."
        )
        _ = try await environment.runStore.appendMessage(
            conversationID: conversation.id,
            role: .assistant,
            content: "We configured deterministic local review queues for this project."
        )
        try await environment.runStore.setRunPhase(run.id, phase: .finished, error: nil)

        let result = try await environment.adapter.captureFinishedRun(
            runID: run.id,
            projectID: firstProject,
            conversationID: conversation.id,
            assistantMessageID: selectedAssistantMessage.id
        )
        let records = try await environment.queue.pendingRecords(in: firstProject)

        XCTAssertEqual(result.outcome, .enqueued)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].candidate.provenance.assistantMessageID, selectedAssistantMessage.id)
        XCTAssertEqual(records[0].candidate.statement, "We decided to use SQLite for local project memory")
    }

    func testFailedAndCancelledRunsCreateNoCandidates() async throws {
        for phase in [LocalRunPhase.failed, .cancelled] {
            let environment = try makeEnvironment()
            environment.preferences.optIn(for: firstProject)
            let evidence = try await makeRun(
                in: environment.runStore,
                phase: phase,
                output: "We decided to use SQLite for local project memory."
            )

            let result = try await environment.adapter.captureFinishedRun(
                runID: evidence.runID,
                projectID: firstProject,
                conversationID: evidence.conversationID,
                assistantMessageID: evidence.assistantMessageID
            )

            let pendingRecords = try await environment.queue.pendingRecords(in: firstProject)
            let graphFacts = try await environment.memoryStore.memories(in: firstProject)

            XCTAssertEqual(result.outcome, .skipped(reason: .runWasNotFinished))
            XCTAssertTrue(pendingRecords.isEmpty)
            XCTAssertTrue(graphFacts.isEmpty)
        }
    }

    func testQueueAndPendingExportAreProjectIsolated() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        environment.preferences.optIn(for: secondProject)
        let firstEvidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )
        let secondEvidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We configured deterministic local review queues for this project."
        )

        _ = try await environment.adapter.captureFinishedRun(
            runID: firstEvidence.runID,
            projectID: firstProject,
            conversationID: firstEvidence.conversationID,
            assistantMessageID: firstEvidence.assistantMessageID
        )
        _ = try await environment.adapter.captureFinishedRun(
            runID: secondEvidence.runID,
            projectID: secondProject,
            conversationID: secondEvidence.conversationID,
            assistantMessageID: secondEvidence.assistantMessageID
        )

        let firstExport = try await environment.queue.exportProject(firstProject)
        let secondExport = try await environment.queue.exportProject(secondProject)
        XCTAssertEqual(firstExport.projectID, firstProject)
        XCTAssertEqual(secondExport.projectID, secondProject)
        XCTAssertEqual(firstExport.records.count, 1)
        XCTAssertEqual(secondExport.records.count, 1)
        XCTAssertTrue(firstExport.records.allSatisfy { $0.projectID == firstProject })
        XCTAssertTrue(secondExport.records.allSatisfy { $0.projectID == secondProject })
        let firstExportJSON = try await environment.queue.exportJSON(forProject: firstProject)
        XCTAssertFalse(String(decoding: firstExportJSON, as: UTF8.self).contains("memory_neurons"))

        _ = try await environment.queue.deletePendingCandidate(
            id: firstExport.records[0].id,
            projectID: firstProject
        )
        let remainingFirstRecords = try await environment.queue.pendingRecords(in: firstProject)
        let remainingSecondRecords = try await environment.queue.pendingRecords(in: secondProject)
        XCTAssertTrue(remainingFirstRecords.isEmpty)
        XCTAssertEqual(remainingSecondRecords.map(\.id), [secondExport.records[0].id])
    }

    func testExplicitUserApprovalCapturesOneGraphFactExactlyOnce() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )
        _ = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let pendingRecords = try await environment.queue.pendingRecords(in: firstProject)
        let pending = try XCTUnwrap(pendingRecords.first)

        let fact = try await environment.queue.approveFromUser(
            candidateID: pending.id,
            projectID: firstProject,
            approvalNote: "Approved after reviewing this unverified model statement.",
            memoryStore: environment.memoryStore
        )
        let memoriesAfterApproval = try await environment.memoryStore.memories(in: firstProject)

        XCTAssertEqual(memoriesAfterApproval.map(\.id), [fact.id])
        XCTAssertEqual(fact.content, pending.candidate.statement)
        XCTAssertEqual(fact.source.kind, .agentProposal)
        XCTAssertTrue(fact.source.label.contains("unverified model statement"))
        XCTAssertTrue(fact.source.reference?.contains(evidence.runID.uuidString.lowercased()) == true)
        XCTAssertTrue(fact.source.reference?.contains(evidence.conversationID.uuidString.lowercased()) == true)
        XCTAssertTrue(fact.source.reference?.contains(evidence.assistantMessageID.uuidString.lowercased()) == true)
        XCTAssertEqual(fact.provenance.sourceRecordID, pending.id)
        let pendingAfterApproval = try await environment.queue.pendingRecords(in: firstProject)
        XCTAssertTrue(pendingAfterApproval.isEmpty)

        do {
            _ = try await environment.queue.approveFromUser(
                candidateID: pending.id,
                projectID: firstProject,
                memoryStore: environment.memoryStore
            )
            XCTFail("A removed pending record must not capture a second graph fact.")
        } catch let error as NativeMemoryPendingCandidateQueueError {
            XCTAssertEqual(error, .recordNotFound(id: pending.id, projectID: firstProject))
        }
        let memoriesAfterSecondApprovalAttempt = try await environment.memoryStore.memories(in: firstProject)
        XCTAssertEqual(memoriesAfterSecondApprovalAttempt.count, 1)
    }

    func testDeletePendingRecordDoesNotCreateGraphFact() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )
        _ = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let pendingRecords = try await environment.queue.pendingRecords(in: firstProject)
        let pending = try XCTUnwrap(pendingRecords.first)

        let deleted = try await environment.queue.deletePendingCandidate(
            id: pending.id,
            projectID: firstProject
        )

        let remainingRecords = try await environment.queue.pendingRecords(in: firstProject)
        let graphFacts = try await environment.memoryStore.memories(in: firstProject)
        XCTAssertEqual(deleted, pending)
        XCTAssertTrue(remainingRecords.isEmpty)
        XCTAssertTrue(graphFacts.isEmpty)
    }

    func testPendingQueuePersistsAcrossRestart() async throws {
        let environment = try makeEnvironment()
        environment.preferences.optIn(for: firstProject)
        let evidence = try await makeRun(
            in: environment.runStore,
            phase: .finished,
            output: "We decided to use SQLite for local project memory."
        )
        _ = try await environment.adapter.captureFinishedRun(
            runID: evidence.runID,
            projectID: firstProject,
            conversationID: evidence.conversationID,
            assistantMessageID: evidence.assistantMessageID
        )
        let beforeRestart = try await environment.queue.pendingRecords(in: firstProject)

        let reopenedQueue = try NativeMemoryPendingCandidateQueue(fileURL: environment.queueURL)
        let afterRestart = try await reopenedQueue.pendingRecords(in: firstProject)

        XCTAssertEqual(afterRestart, beforeRestart)
    }

    func testCorruptQueueStateFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let queueURL = directory.appendingPathComponent("NativeMemoryPendingCandidates.json")
        try Data("{ this is not JSON".utf8).write(to: queueURL, options: .atomic)

        XCTAssertThrowsError(try NativeMemoryPendingCandidateQueue(fileURL: queueURL)) { error in
            XCTAssertEqual(error as? NativeMemoryPendingCandidateQueueError, .corruptData)
        }
    }

    private func makeEnvironment() throws -> Environment {
        let directory = try makeTemporaryDirectory()
        let runStore = try LocalRunStore(databaseURL: directory.appendingPathComponent("runs.sqlite"))
        let memoryStore = try LocalNeuralMemoryStore(databaseURL: directory.appendingPathComponent("memory.sqlite"))
        let queueURL = directory.appendingPathComponent("NativeMemoryPendingCandidates.json")
        let queue = try NativeMemoryPendingCandidateQueue(fileURL: queueURL)
        let suiteName = "native-memory-automatic-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = NativeMemoryAutocapturePreferenceStore(defaults: defaults)
        let adapter = NativeMemoryAutocaptureLifecycleAdapter(
            runStore: runStore,
            pendingQueue: queue,
            preferenceStore: preferences,
            extractor: NativeMemoryAutocaptureCandidateExtractor()
        )
        return Environment(
            runStore: runStore,
            memoryStore: memoryStore,
            queue: queue,
            queueURL: queueURL,
            preferences: preferences,
            defaults: defaults,
            suiteName: suiteName,
            adapter: adapter
        )
    }

    private func makeRun(
        in store: LocalRunStore,
        phase: LocalRunPhase,
        output: String
    ) async throws -> RunEvidence {
        let conversation = try await store.createConversation(title: "Automatic memory")
        let run = try await store.createRun(conversationID: conversation.id)
        let assistantMessage = try await store.appendMessage(
            conversationID: conversation.id,
            role: .assistant,
            content: output
        )
        try await store.setRunPhase(
            run.id,
            phase: phase,
            error: phase == .failed ? "Failure" : nil
        )
        return RunEvidence(
            conversationID: conversation.id,
            runID: run.id,
            assistantMessageID: assistantMessage.id
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private struct Environment {
        let runStore: LocalRunStore
        let memoryStore: LocalNeuralMemoryStore
        let queue: NativeMemoryPendingCandidateQueue
        let queueURL: URL
        let preferences: NativeMemoryAutocapturePreferenceStore
        let defaults: UserDefaults
        let suiteName: String
        let adapter: NativeMemoryAutocaptureLifecycleAdapter
    }

    private struct RunEvidence {
        let conversationID: UUID
        let runID: UUID
        let assistantMessageID: UUID
    }
}
