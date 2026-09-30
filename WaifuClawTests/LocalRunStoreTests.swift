import Foundation
import SQLite3
import XCTest
@testable import WaifuClaw

final class LocalRunStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testPersistsConversationMessageRunAndEventAfterReopening() async throws {
        let databaseURL = try makeDatabaseURL()
        let firstStore = try LocalRunStore(databaseURL: databaseURL)
        let conversation = try await firstStore.createConversation(title: "Refactor parser")
        let message = try await firstStore.appendMessage(
            conversationID: conversation.id,
            role: .user,
            content: "Extract the tokenizer."
        )
        let run = try await firstStore.createRun(conversationID: conversation.id)
        let event = try await firstStore.appendEvent(
            runID: run.id,
            kind: "tool",
            summary: "Read Sources/Parser.swift"
        )
        try await firstStore.setRunPhase(run.id, phase: .finished, error: nil)

        let reopenedStore = try LocalRunStore(databaseURL: databaseURL)
        let conversations = try await reopenedStore.listConversations()
        let messages = try await reopenedStore.messages(in: conversation.id)
        let runs = try await reopenedStore.runs(in: conversation.id)
        let events = try await reopenedStore.events(in: run.id)

        XCTAssertEqual(conversations.map(\.id), [conversation.id])
        XCTAssertEqual(messages, [message])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].id, run.id)
        XCTAssertEqual(runs[0].phase, .finished)
        XCTAssertNil(runs[0].errorMessage)
        XCTAssertEqual(events, [event])
    }

    func testOrderingIsChronologicalAndConversationsUseRecentActivity() async throws {
        let store = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let olderConversation = try await store.createConversation(title: "Older")
        try await pauseForClockTick()
        let newerConversation = try await store.createConversation(title: "Newer")

        try await pauseForClockTick()
        let firstMessage = try await store.appendMessage(
            conversationID: olderConversation.id,
            role: .user,
            content: "First"
        )
        try await pauseForClockTick()
        let secondMessage = try await store.appendMessage(
            conversationID: olderConversation.id,
            role: .assistant,
            content: "Second"
        )

        let orderedMessages = try await store.messages(in: olderConversation.id)
        let orderedConversations = try await store.listConversations()

        XCTAssertEqual(orderedMessages.map(\.id), [firstMessage.id, secondMessage.id])
        XCTAssertEqual(orderedConversations.map(\.id), [olderConversation.id, newerConversation.id])
    }

    func testCancellationPersistsWithoutErrorMessage() async throws {
        let store = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let conversation = try await store.createConversation(title: "Cancellation")
        let run = try await store.createRun(conversationID: conversation.id)

        try await store.setRunPhase(run.id, phase: .cancelled, error: nil)

        let savedRuns = try await store.runs(in: conversation.id)
        let savedRun = try XCTUnwrap(savedRuns.first)
        XCTAssertEqual(savedRun.phase, .cancelled)
        XCTAssertNil(savedRun.errorMessage)
        XCTAssertGreaterThanOrEqual(savedRun.updatedAt, run.updatedAt)
    }

    func testMessagesAndRunsAreIsolatedPerConversation() async throws {
        let store = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let firstConversation = try await store.createConversation(title: "First")
        let secondConversation = try await store.createConversation(title: "Second")

        let firstMessage = try await store.appendMessage(
            conversationID: firstConversation.id,
            role: .user,
            content: "Only first"
        )
        let secondMessage = try await store.appendMessage(
            conversationID: secondConversation.id,
            role: .user,
            content: "Only second"
        )
        let firstRun = try await store.createRun(conversationID: firstConversation.id)
        let secondRun = try await store.createRun(conversationID: secondConversation.id)

        let firstMessages = try await store.messages(in: firstConversation.id)
        let secondMessages = try await store.messages(in: secondConversation.id)
        let firstRuns = try await store.runs(in: firstConversation.id)
        let secondRuns = try await store.runs(in: secondConversation.id)

        XCTAssertEqual(firstMessages.map(\.id), [firstMessage.id])
        XCTAssertEqual(secondMessages.map(\.id), [secondMessage.id])
        XCTAssertEqual(firstRuns.map(\.id), [firstRun.id])
        XCTAssertEqual(secondRuns.map(\.id), [secondRun.id])
    }

    func testInvalidForeignKeysAreRejected() async throws {
        let store = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let missingConversationID = UUID()

        do {
            _ = try await store.appendMessage(
                conversationID: missingConversationID,
                role: .user,
                content: "This parent does not exist."
            )
            XCTFail("Expected a foreign-key constraint error")
        } catch let error as LocalRunStoreError {
            guard case .sqlite(let code, _) = error else {
                return XCTFail("Expected SQLite constraint error, got \(error)")
            }
            XCTAssertEqual(code, SQLITE_CONSTRAINT)
        }

        do {
            _ = try await store.createRun(conversationID: missingConversationID)
            XCTFail("Expected a foreign-key constraint error")
        } catch let error as LocalRunStoreError {
            guard case .sqlite(let code, _) = error else {
                return XCTFail("Expected SQLite constraint error, got \(error)")
            }
            XCTAssertEqual(code, SQLITE_CONSTRAINT)
        }

        do {
            _ = try await store.appendEvent(
                runID: UUID(),
                kind: "tool",
                summary: "No parent run"
            )
            XCTFail("Expected a foreign-key constraint error")
        } catch let error as LocalRunStoreError {
            guard case .sqlite(let code, _) = error else {
                return XCTFail("Expected SQLite constraint error, got \(error)")
            }
            XCTAssertEqual(code, SQLITE_CONSTRAINT)
        }
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("LocalRunStore.sqlite", isDirectory: false)
    }

    private func pauseForClockTick() async throws {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
