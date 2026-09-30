import Foundation
import XCTest
@testable import WaifuClaw

final class NativeAgentEngineTests: XCTestCase {
    func testCompletesAndPersistsAProviderResponse() async throws {
        let store = try LocalRunStore(databaseURL: try temporaryDatabaseURL())
        let conversation = try await store.createConversation(title: "Native run")
        let provider = SequencedTestProvider([[.text("Hello from model"), .finished]])
        let engine = NativeAgentEngine(store: store)
        var text = ""
        for try await signal in await engine.stream(
            conversationID: conversation.id,
            prompt: "Hello",
            provider: provider,
            workspace: nil
        ) {
            if case .text(let chunk) = signal { text += chunk }
        }
        XCTAssertEqual(text, "Hello from model")
        let messages = try await store.messages(in: conversation.id)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["Hello", "Hello from model"])
        let runs = try await store.runs(in: conversation.id)
        XCTAssertEqual(runs.map(\.phase), [.finished])
        let events = try await store.events(in: try XCTUnwrap(runs.first).id)
        XCTAssertEqual(events.map(\.kind), ["run.started", "run.completed"])
    }

    func testDeniedToolPathIsRecordedAsFailureNotSentAsFileContent() async throws {
        let store = try LocalRunStore(databaseURL: try temporaryDatabaseURL())
        let conversation = try await store.createConversation(title: "Path safety")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let workspace = try ScopedWorkspace(rootURL: folder)
        let provider = SequencedTestProvider([
            [.toolCall(AgentToolCall(id: "call1", name: "read_file", argumentsJSON: #"{"path":"../private.txt"}"#)), .finished],
            [.text("I cannot read outside the project."), .finished]
        ])
        let engine = NativeAgentEngine(store: store)
        for try await _ in await engine.stream(
            conversationID: conversation.id,
            prompt: "Read a private file",
            provider: provider,
            workspace: workspace
        ) {}
        let runs = try await store.runs(in: conversation.id)
        XCTAssertEqual(runs.first?.phase, .finished)
        let events = try await store.events(in: try XCTUnwrap(runs.first).id)
        XCTAssertTrue(events.map(\.kind).contains("tool.failed"))
        let messages = try await store.messages(in: conversation.id)
        XCTAssertFalse(messages.contains(where: { $0.content.contains("private file contents") }))
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("runs.sqlite")
    }
}

/// Deliberately test-target only. The shipped app has no synthetic provider.
private final class SequencedTestProvider: AgentModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [[AgentProviderEvent]]
    private var index = 0

    init(_ replies: [[AgentProviderEvent]]) { self.replies = replies }

    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        lock.lock()
        let reply = replies[min(index, replies.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in reply { continuation.yield(event) }
            continuation.finish()
        }
    }
}
