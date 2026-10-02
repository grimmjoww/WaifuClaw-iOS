import Foundation
import XCTest
@testable import WaifuClaw

final class NativeTeamTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testWorkersUseDistinctRunsPersistHistoryAndDoNotReceiveProjectToolsWithoutConsent() async throws {
        let runStore = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let historyDirectory = try makeTemporaryDirectory()
        let historyStore = try NativeTeamWorkflowStore(directoryURL: historyDirectory)
        let workspaceDirectory = try makeTemporaryDirectory()
        try "struct Example {}".write(
            to: workspaceDirectory.appendingPathComponent("Example.swift"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = try ScopedWorkspace(rootURL: workspaceDirectory)
        let provider = TeamRecordingTestProvider()
        let coordinator = NativeTeamWorkflowCoordinator(
            runStore: runStore,
            workflowStore: historyStore
        )

        let workflow = try await coordinator.start(
            goal: "Assess a small refactor",
            provider: provider,
            workspace: workspace,
            projectReadEnabled: false
        )

        XCTAssertEqual(workflow.phase, .completed)
        XCTAssertEqual(workflow.workers.map(\.role), NativeTeamRole.workerRoles)
        XCTAssertEqual(Set(workflow.workers.map(\.conversationID)).count, 3)
        let workerRunIDs = try workflow.workers.map { try XCTUnwrap($0.runID) }
        XCTAssertEqual(Set(workerRunIDs).count, 3)
        XCTAssertTrue(workflow.workers.allSatisfy { $0.runPhase == .finished })
        XCTAssertFalse(workflow.workers.contains { $0.projectReadAllowed })
        XCTAssertEqual(workflow.supervisor.runPhase, .finished)
        XCTAssertNotNil(workflow.supervisor.runID)
        XCTAssertNotNil(workflow.finalSynthesis)

        for worker in workflow.workers {
            let runs = try await runStore.runs(in: worker.conversationID)
            XCTAssertEqual(runs.map(\.id), [try XCTUnwrap(worker.runID)])
            XCTAssertEqual(runs.map(\.phase), [.finished])
        }

        let invocations = provider.invocations()
        XCTAssertEqual(invocations.count, 4)
        XCTAssertTrue(invocations.allSatisfy { $0.toolNames.isEmpty })
        XCTAssertEqual(Set(invocations.map(\.role)), Set(NativeTeamRole.allCases))

        // Reopen the Team-specific durable history instead of relying on the
        // in-memory actor. Exact LocalRunStore links and bounded excerpts remain.
        let reopenedHistory = try NativeTeamWorkflowStore(directoryURL: historyDirectory)
        let reloaded = try await reopenedHistory.workflow(id: workflow.id)
        XCTAssertEqual(reloaded.id, workflow.id)
        XCTAssertEqual(reloaded.workers.map(\.conversationID), workflow.workers.map(\.conversationID))
        XCTAssertEqual(reloaded.workers.map(\.runID), workflow.workers.map(\.runID))
        XCTAssertEqual(reloaded.finalSynthesis, workflow.finalSynthesis)
    }

    func testPartialWorkerFailureIsRecordedAndSupervisorSynthesizesAvailableEvidence() async throws {
        let runStore = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let historyStore = try NativeTeamWorkflowStore(directoryURL: try makeTemporaryDirectory())
        let provider = TeamRecordingTestProvider(failingRole: .riskReviewer)
        let coordinator = NativeTeamWorkflowCoordinator(
            runStore: runStore,
            workflowStore: historyStore
        )

        let workflow = try await coordinator.start(
            goal: "Plan a safe migration",
            provider: provider,
            workspace: nil,
            projectReadEnabled: false
        )

        XCTAssertEqual(workflow.phase, .partialFailure)
        let failedWorker = try XCTUnwrap(workflow.workers.first(where: { $0.role == .riskReviewer }))
        XCTAssertEqual(failedWorker.runPhase, .failed)
        XCTAssertNotNil(failedWorker.errorMessage)
        XCTAssertTrue(workflow.workers.contains { $0.runPhase == .finished })
        XCTAssertEqual(workflow.supervisor.runPhase, .finished)
        XCTAssertTrue(workflow.finalSynthesis?.contains("Supervisor") == true)

        let saved = try await historyStore.workflow(id: workflow.id)
        XCTAssertEqual(saved.workers.first(where: { $0.role == .riskReviewer })?.runID, failedWorker.runID)
        XCTAssertEqual(saved.phase, .partialFailure)
    }

    func testCancellationMarksWorkflowAndUnfinishedRunsCancelled() async throws {
        let runStore = try LocalRunStore(databaseURL: try makeDatabaseURL())
        let historyStore = try NativeTeamWorkflowStore(directoryURL: try makeTemporaryDirectory())
        let provider = WaitingTeamTestProvider()
        let coordinator = NativeTeamWorkflowCoordinator(
            runStore: runStore,
            workflowStore: historyStore
        )

        let operation = Task {
            try await coordinator.start(
                goal: "Wait for cancellation",
                provider: provider,
                workspace: nil,
                projectReadEnabled: false
            )
        }

        for _ in 0..<100 where provider.invocationCount() < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(provider.invocationCount(), 3)
        operation.cancel()
        let workflow = try await operation.value

        XCTAssertEqual(workflow.phase, .cancelled)
        XCTAssertTrue(workflow.workers.allSatisfy { $0.runPhase == .cancelled })
        for worker in workflow.workers {
            let runs = try await runStore.runs(in: worker.conversationID)
            XCTAssertEqual(runs.map(\.phase), [.cancelled])
        }
        let saved = try await historyStore.workflow(id: workflow.id)
        XCTAssertEqual(saved.phase, .cancelled)
        XCTAssertTrue(saved.statusNote?.contains("not completed") == true)
    }

    func testReloadMarksUnfinishedWorkflowInterruptedWithoutClaimingCompletion() async throws {
        let historyDirectory = try makeTemporaryDirectory()
        let originalStore = try NativeTeamWorkflowStore(directoryURL: historyDirectory)
        let workers = NativeTeamRole.workerRoles.map {
            NativeTeamWorkerEvidence(
                role: $0,
                conversationID: UUID(),
                projectReadAllowed: false
            )
        }
        let created = try await originalStore.create(
            userGoal: "Recover a suspended workflow",
            projectReadAllowed: false,
            workers: workers,
            supervisor: NativeTeamSupervisorEvidence(conversationID: UUID())
        )

        let reopenedStore = try NativeTeamWorkflowStore(directoryURL: historyDirectory)
        let recovered = try await reopenedStore.workflow(id: created.id)

        XCTAssertEqual(recovered.phase, .interrupted)
        XCTAssertNil(recovered.finalSynthesis)
        XCTAssertTrue(recovered.statusNote?.contains("not completed") == true)
    }

    private func makeDatabaseURL() throws -> URL {
        try makeTemporaryDirectory().appendingPathComponent("LocalRunStore.sqlite", isDirectory: false)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

/// Deliberately XCTest-only. The shipped Team workflow has no synthetic or
/// fallback provider; it receives a real user-configured BYOK provider from its
/// controller.
private final class TeamRecordingTestProvider: AgentModelProvider, @unchecked Sendable {
    struct Invocation: Sendable {
        let role: NativeTeamRole
        let toolNames: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []
    private let failingRole: NativeTeamRole?

    init(failingRole: NativeTeamRole? = nil) {
        self.failingRole = failingRole
    }

    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        let role = roleFor(messages)
        lock.lock()
        recordedInvocations.append(Invocation(role: role, toolNames: tools.map(\.name)))
        lock.unlock()

        return AsyncThrowingStream { continuation in
            if role == failingRole {
                continuation.finish(throwing: TeamTestProviderError.intentionalFailure)
            } else {
                let text: String
                if role == .supervisor {
                    text = "Supervisor synthesis based on the recorded worker evidence."
                } else {
                    text = "\(role.displayName) evidence for the requested goal."
                }
                continuation.yield(.text(text))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    func invocations() -> [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    private func roleFor(_ messages: [AgentPromptMessage]) -> NativeTeamRole {
        let system = messages.first(where: { $0.role == "system" })?.content ?? ""
        if system.contains("Supervisor for a phone-local") { return .supervisor }
        if system.contains("Explorer in a bounded") { return .explorer }
        if system.contains("Risk Reviewer in a bounded") { return .riskReviewer }
        if system.contains("Implementation Planner in a bounded") { return .implementationPlanner }
        return .supervisor
    }
}

private final class WaitingTeamTestProvider: AgentModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error> {
        lock.lock()
        count += 1
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let waitingTask = Task {
                do {
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in waitingTask.cancel() }
        }
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum TeamTestProviderError: LocalizedError {
    case intentionalFailure

    var errorDescription: String? {
        "Intentional deterministic provider failure."
    }
}
