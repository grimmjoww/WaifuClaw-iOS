import Foundation
import Observation

/// Main-actor adapter for the Team screen. It intentionally creates one real
/// configured BYOK provider per user-started workflow and passes that same
/// provider to all three workers and the supervisor.
@Observable
@MainActor
final class NativeTeamWorkflowController {
    var goal = ""
    /// Deliberately session-only and false by default. Enabling it is explicit
    /// consent for workers (not the supervisor) to receive read-only file tools.
    var projectReadEnabled = false
    var workspaceName: String?
    var workflows: [NativeTeamWorkflowRecord] = []
    var selectedWorkflowID: UUID?
    var status = "Enter a goal to begin a phone-local workflow."
    var errorMessage: String?
    var isRunning = false

    private var runStore: LocalRunStore?
    private var workflowStore: NativeTeamWorkflowStore?
    private var selectedWorkspace: ScopedWorkspace?
    private var activeTask: Task<Void, Never>?
    private static let workspaceBookmarkKey = "native.workspace.folderBookmark"

    init() {
        restoreWorkspace()
    }

    var selectedWorkflow: NativeTeamWorkflowRecord? {
        guard let selectedWorkflowID else { return workflows.first }
        return workflows.first(where: { $0.id == selectedWorkflowID })
    }

    func load() async {
        restoreWorkspace()
        do {
            let store = try resolvedWorkflowStore()
            workflows = await store.list()
            if selectedWorkflowID == nil || !workflows.contains(where: { $0.id == selectedWorkflowID }) {
                selectedWorkflowID = workflows.first?.id
            }
            if workflows.isEmpty {
                status = "No Team workflows have been saved on this iPhone."
            } else if let selected = selectedWorkflow {
                status = selected.phase.displayName
            }
        } catch {
            present(error)
        }
    }

    func reload() async {
        guard !isRunning else { return }
        await load()
    }

    func selectWorkflow(_ id: UUID) {
        selectedWorkflowID = id
        if let record = selectedWorkflow {
            status = record.phase.displayName
        }
    }

    func selectWorkspace(_ url: URL) {
        guard !isRunning else { return }
        do {
            let workspace = try ScopedWorkspace(rootURL: url)
            _ = try NativeProjectPermission().selectFolder(url)
            selectedWorkspace = workspace
            workspaceName = url.lastPathComponent
            errorMessage = nil
            status = "Project selected. Project reading remains off until you explicitly enable it."
        } catch {
            present(error)
        }
    }

    func start() {
        guard !isRunning else { return }
        let requestedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedGoal.isEmpty else {
            errorMessage = NativeTeamWorkflowError.emptyGoal.errorDescription
            return
        }
        guard requestedGoal.count <= NativeTeamLimits.goalCharacters else {
            errorMessage = NativeTeamWorkflowError.goalTooLong.errorDescription
            return
        }

        // Re-resolve the bookmark at the moment consent is used, so a revoked
        // Files grant cannot be silently treated as an authorized project.
        restoreWorkspace()
        if projectReadEnabled && selectedWorkspace == nil {
            errorMessage = "Project access needs renewal in Files. Re-select the folder or turn off project reading before starting."
            return
        }
        isRunning = true
        errorMessage = nil
        status = "Starting three independent BYOK worker runs…"
        activeTask = Task { await run(goal: requestedGoal) }
    }

    func cancel() {
        guard isRunning else { return }
        status = "Cancelling workers and any supervisor synthesis…"
        activeTask?.cancel()
    }

    private func run(goal: String) async {
        do {
            let provider = try configuredProvider()
            let runStore = try resolvedRunStore()
            let workflowStore = try resolvedWorkflowStore()
            let coordinator = NativeTeamWorkflowCoordinator(
                runStore: runStore,
                workflowStore: workflowStore
            )
            let record = try await coordinator.start(
                goal: goal,
                provider: provider,
                workspace: selectedWorkspace,
                projectReadEnabled: projectReadEnabled
            )
            self.goal = ""
            await refreshHistory(selecting: record.id)
            status = record.phase.displayName
            if record.phase == .partialFailure || record.phase == .failed {
                errorMessage = record.statusNote
            }
        } catch is CancellationError {
            // The coordinator normally converts cancellation to a durable Team
            // record. This fallback keeps the UI honest if setup was cancelled
            // before it could create one.
            status = "Cancelled before a Team workflow could start."
        } catch {
            present(error)
            status = "Team workflow did not start."
        }
        isRunning = false
        activeTask = nil
    }

    private func refreshHistory(selecting workflowID: UUID? = nil) async {
        guard let workflowStore else { return }
        workflows = await workflowStore.list()
        if let workflowID, workflows.contains(where: { $0.id == workflowID }) {
            selectedWorkflowID = workflowID
        } else if selectedWorkflowID == nil || !workflows.contains(where: { $0.id == selectedWorkflowID }) {
            selectedWorkflowID = workflows.first?.id
        }
    }

    private func resolvedRunStore() throws -> LocalRunStore {
        if let runStore { return runStore }
        let created = try LocalRunStore()
        runStore = created
        return created
    }

    private func resolvedWorkflowStore() throws -> NativeTeamWorkflowStore {
        if let workflowStore { return workflowStore }
        let created = try NativeTeamWorkflowStore()
        workflowStore = created
        return created
    }

    private func configuredProvider() throws -> any AgentModelProvider {
        let configuration = try LocalModelPreferences.load()
        guard let key = try KeychainStore.agentKey() else {
            throw LocalModelConfigurationError.missingKey
        }
        // The provider owns the key only in memory while this Task runs. Neither
        // Team history nor LocalRunStore receives it.
        return try OpenAICompatibleProvider(
            baseURL: configuration.endpoint,
            model: configuration.model,
            apiKey: key
        )
    }

    private func restoreWorkspace() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.workspaceBookmarkKey) else {
            selectedWorkspace = nil
            workspaceName = nil
            return
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw ScopedWorkspace.WorkspaceError.invalidFolder }
            selectedWorkspace = try ScopedWorkspace(rootURL: url)
            workspaceName = url.lastPathComponent
        } catch {
            selectedWorkspace = nil
            workspaceName = nil
            errorMessage = "The saved project folder is unavailable. Choose it again before enabling project reading."
        }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
