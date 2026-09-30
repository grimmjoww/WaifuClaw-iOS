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

    func testModelEditToolCreatesOnlyAPendingProposalAndNeverWritesWorkspace() async throws {
        let store = try LocalRunStore(databaseURL: try temporaryDatabaseURL())
        let conversation = try await store.createConversation(title: "Reviewable edit")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let workspace = try ScopedWorkspace(rootURL: folder)
        let project = try NativePatchProject(userSelectedFolderURL: folder)
        let patchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: patchDirectory) }
        let workflow = try NativePatchWorkflow(
            persistenceDirectoryURL: patchDirectory
        )
        let arguments = NativePatchModelEditArguments(
            relativePath: "note.txt",
            expectedSHA256: NativePatchDigest.sha256(Data("before\n".utf8)),
            newText: "after\n",
            reason: "Change the text"
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(arguments), encoding: .utf8))
        let provider = SequencedTestProvider([
            [.toolCall(AgentToolCall(id: "read1", name: "read_file", argumentsJSON: #"{"path":"note.txt"}"#)), .finished],
            [.toolCall(AgentToolCall(id: "edit1", name: "propose_edit", argumentsJSON: json)), .finished],
            [.text("I proposed a change. Review it before it is applied."), .finished]
        ])
        var proposedIDs: [UUID] = []
        let engine = NativeAgentEngine(store: store)
        for try await signal in await engine.stream(
            conversationID: conversation.id,
            prompt: "Update note.txt",
            provider: provider,
            workspace: workspace,
            patchWorkflow: workflow,
            patchProject: project
        ) {
            if case .patchProposed(let id) = signal { proposedIDs.append(id) }
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")
        let pending = try workflow.pendingProposals(in: project)
        XCTAssertEqual(pending.map(\.id), proposedIDs)
        XCTAssertEqual(pending.first?.status, .pending)
        let runs = try await store.runs(in: conversation.id)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.phase, .finished)
        let events = try await store.events(in: run.id)
        XCTAssertTrue(events.map(\.kind).contains("patch.proposed"))
        XCTAssertFalse(events.map(\.kind).contains("patch.applied"))
    }

    func testProjectMemoryIsSharedOnlyWithConsentDuringRealAgentRun() async throws {
        let store = try LocalRunStore(databaseURL: try temporaryDatabaseURL())
        let memory = try LocalNeuralMemoryStore(databaseURL: try temporaryDatabaseURL())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let projectID = NativeProjectIdentity.id(for: folder)
        _ = try await memory.capture(
            LocalMemoryCaptureRequest(
                projectID: projectID,
                fact: "The project must use SQLite for cached notes.",
                source: LocalMemorySource(kind: .manualNote, label: "Approved project note"),
                provenance: LocalMemoryProvenance(capturedBy: "user")
            ), approval: .userApproved
        )
        _ = try await memory.capture(
            LocalMemoryCaptureRequest(
                projectID: String(repeating: "b", count: 64),
                fact: "Other project's private memory must never be shared.",
                source: LocalMemorySource(kind: .manualNote, label: "Other project note"),
                provenance: LocalMemoryProvenance(capturedBy: "user")
            ), approval: .userApproved
        )
        let conversation = try await store.createConversation(title: "Project memory")
        let workspace = try ScopedWorkspace(rootURL: folder)
        let enabled = SequencedTestProvider([[.text("The project uses SQLite."), .finished]])
        let engine = NativeAgentEngine(store: store, memoryStore: memory)
        for try await _ in await engine.stream(
            conversationID: conversation.id, prompt: "How do we store cached notes?",
            provider: enabled, workspace: workspace, memoryEnabled: true
        ) {}
        let context = try XCTUnwrap(enabled.capturedMessages().first?.first?.content)
        XCTAssertTrue(context.contains("SQLite for cached notes"))
        XCTAssertFalse(context.contains("Other project's private memory"))
        let firstRuns = try await store.runs(in: conversation.id)
        let firstRun = try XCTUnwrap(firstRuns.first)
        let firstEvents = try await store.events(in: firstRun.id)
        XCTAssertTrue(firstEvents.map(\.kind).contains("memory.recalled"))

        let disabled = SequencedTestProvider([[.text("I can answer without memory."), .finished]])
        for try await _ in await engine.stream(
            conversationID: conversation.id, prompt: "How do we store cached notes?",
            provider: disabled, workspace: workspace, memoryEnabled: false
        ) {}
        let noMemoryContext = try XCTUnwrap(disabled.capturedMessages().first?.first?.content)
        XCTAssertFalse(noMemoryContext.contains("SQLite for cached notes"))
        let laterRuns = try await store.runs(in: conversation.id)
        let latestRun = try XCTUnwrap(laterRuns.last)
        let laterEvents = try await store.events(in: latestRun.id)
        XCTAssertFalse(laterEvents.map(\.kind).contains("memory.recalled"))
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
    private var seenMessages: [[AgentPromptMessage]] = []

    init(_ replies: [[AgentProviderEvent]]) { self.replies = replies }

    func capturedMessages() -> [[AgentPromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return seenMessages
    }

    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        lock.lock()
        let reply = replies[min(index, replies.count - 1)]
        seenMessages.append(messages)
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in reply { continuation.yield(event) }
            continuation.finish()
        }
    }
}
