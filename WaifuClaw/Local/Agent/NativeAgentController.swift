import Foundation
import Observation

@Observable
@MainActor
final class NativeAgentController {
    var conversations: [LocalConversation] = []
    var selectedConversationID: UUID?
    var messages: [LocalMessage] = []
    var recentEvents: [LocalRunEvent] = []
    var draft = ""
    var streamedText = ""
    var status = "Ready"
    var errorMessage: String?
    var isRunning = false
    var workspaceName: String?
    var klineMood: KlineSpriteMood = .idle
    var pendingPatches: [NativePatchProposal] = []
    var patchPreview: NativePatchApprovalPreview?
    var lastAppliedPatch: NativePatchProposal?
    var isApplyingPatch = false

    private var store: LocalRunStore?
    private var selectedWorkspace: ScopedWorkspace?
    private var selectedPatchProject: NativePatchProject?
    private var patchWorkflow: NativePatchWorkflow?
    private var activeTask: Task<Void, Never>?
    private static let bookmarkKey = "native.workspace.folderBookmark"

    init() {
        do { patchWorkflow = try NativePatchWorkflow() }
        catch { show(error) }
        restoreWorkspace()
    }

    func load() async {
        do {
            let store = try store ?? LocalRunStore()
            self.store = store
            conversations = try await store.listConversations()
            if let selectedConversationID,
               conversations.contains(where: { $0.id == selectedConversationID }) {
                try await loadConversation(selectedConversationID)
            } else if let first = conversations.first {
                try await loadConversation(first.id)
            } else {
                selectedConversationID = nil
                messages = []
                recentEvents = []
                streamedText = ""
                status = "No local conversations yet"
                klineMood = .idle
            }
            refreshPendingPatches()
        } catch {
            show(error)
        }
    }

    func newConversation() {
        guard !isRunning else { return }
        selectedConversationID = nil
        messages = []
        recentEvents = []
        streamedText = ""
        errorMessage = nil
        status = "New conversation"
        klineMood = .idle
    }

    func selectConversation(_ id: UUID) async {
        guard !isRunning else { return }
        do { try await loadConversation(id) }
        catch { show(error) }
    }

    func selectWorkspace(_ url: URL) {
        guard !isRunning, !isApplyingPatch else { return }
        do {
            let workspace = try ScopedWorkspace(rootURL: url)
            let patchProject = try NativePatchProject(userSelectedFolderURL: url)
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            if selectedPatchProject?.projectID != patchProject.projectID {
                patchPreview = nil
                lastAppliedPatch = nil
            }
            selectedWorkspace = workspace
            selectedPatchProject = patchProject
            workspaceName = url.lastPathComponent
            errorMessage = nil
            status = "Project selected: \(url.lastPathComponent)"
            refreshPendingPatches()
        } catch {
            show(error)
        }
    }

    func refreshWorkspace() {
        guard !isRunning, !isApplyingPatch else { return }
        restoreWorkspace()
        refreshPendingPatches()
    }

    func send() {
        guard !isRunning, !isApplyingPatch else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isRunning = true
        klineMood = .thinking
        activeTask = Task { await run(prompt: prompt) }
    }

    func stop() {
        guard isRunning else { return }
        activeTask?.cancel()
        status = "Stopping this phone's agent…"
    }

    private func run(prompt: String) async {
        errorMessage = nil
        streamedText = ""
        var activeRunID: UUID?
        let runProjectID = selectedWorkspace.map { NativeProjectIdentity.id(for: $0.rootURL) }
        let runPatchProject = selectedPatchProject
        let runPatchWorkflow = patchWorkflow
        do {
            let configuration = try LocalModelPreferences.load()
            guard let key = try KeychainStore.agentKey() else {
                throw LocalModelConfigurationError.missingKey
            }
            let provider = try OpenAICompatibleProvider(
                baseURL: configuration.endpoint,
                model: configuration.model,
                apiKey: key
            )
            let store = try store ?? LocalRunStore()
            self.store = store
            let conversationID: UUID
            if let selectedConversationID {
                conversationID = selectedConversationID
            } else {
                let conversation = try await store.createConversation(
                    title: String(prompt.prefix(70))
                )
                conversationID = conversation.id
                selectedConversationID = conversationID
            }
            draft = ""
            isRunning = true
            status = "Thinking on this iPhone…"
            klineMood = .thinking
            let useJev = JevDecisionPreferences().isDecisionOptedIn
            let jevKey = useJev ? (try? JevKeychainStore().load()) : nil
            let useMemory = NativeMemoryConsent().isEnabled(for: runProjectID)
            let engine = NativeAgentEngine(store: store)
            for try await signal in await engine.stream(
                conversationID: conversationID,
                prompt: prompt,
                provider: provider,
                workspace: selectedWorkspace,
                jevEnabled: useJev,
                jevKey: jevKey,
                memoryEnabled: useMemory,
                patchWorkflow: runPatchWorkflow,
                patchProject: runPatchProject
            ) {
                switch signal {
                case .started(let id):
                    activeRunID = id
                    messages = try await store.messages(in: conversationID)
                    status = "Working on this iPhone…"
                    klineMood = .thinking
                case .text(let chunk):
                    streamedText += chunk
                case .toolActivity(let activity):
                    status = activity
                    klineMood = activity.contains("read_file") || activity.contains("list_files") ? .reading : .thinking
                    await refreshRunEvidence(conversationID: conversationID, store: store)
                case .patchProposed:
                    refreshPendingPatches()
                    status = "Edit proposed; no file changed. Review the diff below."
                    klineMood = .reading
                case .completed(let assistantMessageID):
                    status = pendingPatches.contains(where: { $0.runID == activeRunID })
                        ? "Response saved; proposed edit awaits your review"
                        : "Run completed and saved on this phone"
                    klineMood = .completed
                    if let activeRunID {
                        recordExtensionHook(.runFinished, runID: activeRunID, projectID: runProjectID)
                        if let runProjectID,
                           NativeMemoryAutocapturePreferenceStore().preference(for: runProjectID) == .optedIn {
                            do {
                                let queue = try NativeMemoryPendingCandidateQueue.shared()
                                let adapter = NativeMemoryAutocaptureLifecycleAdapter(
                                    runStore: store,
                                    pendingQueue: queue
                                )
                                let capture = try await adapter.captureFinishedRun(
                                    runID: activeRunID,
                                    projectID: runProjectID,
                                    conversationID: conversationID,
                                    assistantMessageID: assistantMessageID
                                )
                                if capture.outcome == .enqueued {
                                    status = "Run saved; \(capture.candidateIDs.count) unverified memory note(s) await review in Memory"
                                    do {
                                        _ = try await store.appendEvent(
                                            runID: activeRunID,
                                            kind: "memory.candidates_queued",
                                            summary: "\(capture.candidateIDs.count) unverified candidate(s) queued for explicit Memory review; no approved fact saved"
                                        )
                                    } catch {
                                        errorMessage = "Memory notes were queued, but their run-evidence receipt could not be saved: \(error.localizedDescription)"
                                    }
                                }
                            } catch {
                                // The agent run remains finished even if optional
                                // local suggestion storage or evidence fails.
                                errorMessage = "The run finished, but automatic memory notes were unavailable: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            messages = try await store.messages(in: conversationID)
            conversations = try await store.listConversations()
            await refreshRunEvidence(conversationID: conversationID, store: store)
            streamedText = ""
        } catch is CancellationError {
            status = "Run stopped on this phone"
            klineMood = .idle
        } catch {
            show(error)
            status = "Run failed"
            klineMood = .failed
            if let activeRunID {
                recordExtensionHook(.runFailed, runID: activeRunID, projectID: runProjectID)
            }
        }
        isRunning = false
        activeTask = nil
        if let store, let selectedConversationID {
            messages = (try? await store.messages(in: selectedConversationID)) ?? messages
            conversations = (try? await store.listConversations()) ?? conversations
            await refreshRunEvidence(conversationID: selectedConversationID, store: store)
        }
    }

    private func loadConversation(_ id: UUID) async throws {
        guard let store else { return }
        selectedConversationID = id
        messages = try await store.messages(in: id)
        await refreshRunEvidence(conversationID: id, store: store)
        status = "Conversation restored from this phone"
        klineMood = .idle
    }

    private func refreshRunEvidence(conversationID: UUID, store: LocalRunStore) async {
        guard let last = try? await store.runs(in: conversationID).last else { return }
        recentEvents = (try? await store.events(in: last.id)) ?? []
    }

    func refreshPendingPatches() {
        guard let patchWorkflow, let selectedPatchProject else {
            pendingPatches = []
            return
        }
        do {
            pendingPatches = try patchWorkflow.pendingProposals(in: selectedPatchProject)
        } catch {
            pendingPatches = []
            show(error)
        }
    }

    func reviewPatch(_ proposal: NativePatchProposal) {
        guard !isRunning, let patchWorkflow, let selectedPatchProject else { return }
        do {
            let preview = try patchWorkflow.approvalPreview(
                proposalID: proposal.id,
                in: selectedPatchProject
            )
            refreshPendingPatches()
            guard preview.isCurrent else {
                patchPreview = nil
                errorMessage = "This edit proposal is no longer current. The project file was not changed."
                return
            }
            patchPreview = preview
            errorMessage = nil
        } catch {
            patchPreview = nil
            show(error)
        }
    }

    func approvePatch(_ proposalID: UUID) async {
        guard !isRunning, !isApplyingPatch,
              patchPreview?.proposal.id == proposalID,
              let patchWorkflow, let selectedPatchProject else { return }
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try patchWorkflow.approveAndApply(proposalID: proposalID, in: selectedPatchProject)
            }.value
            patchPreview = nil
            refreshPendingPatches()
            if outcome.didWriteWorkspace && outcome.proposal.status == .applied {
                lastAppliedPatch = outcome.proposal
                status = "Approved edit saved to \(outcome.proposal.relativePath)"
                await recordPatchEvent(outcome.proposal, kind: "patch.applied", summary: "User approved and saved \(outcome.proposal.relativePath)")
            } else {
                status = "Edit not applied; the project file changed after review"
                errorMessage = "The proposal was invalidated. Reload the file and ask for a new proposal."
                await recordPatchEvent(outcome.proposal, kind: "patch.invalidated", summary: "Approval refused a changed project file")
            }
        } catch {
            show(error)
            refreshPendingPatches()
        }
    }

    func rejectPatch(_ proposalID: UUID) {
        guard !isRunning, !isApplyingPatch,
              let patchWorkflow, let selectedPatchProject else { return }
        do {
            let rejected = try patchWorkflow.reject(proposalID: proposalID, in: selectedPatchProject)
            patchPreview = nil
            status = "Proposed edit rejected; no file changed"
            refreshPendingPatches()
            Task { await recordPatchEvent(rejected, kind: "patch.rejected", summary: "User declined edit to \(rejected.relativePath)") }
        } catch {
            show(error)
        }
    }

    func undoLastApprovedPatch() async {
        guard !isRunning, !isApplyingPatch,
              let lastAppliedPatch, let patchWorkflow, let selectedPatchProject else { return }
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try patchWorkflow.undoLastApprovedSave(proposalID: lastAppliedPatch.id, in: selectedPatchProject)
            }.value
            self.lastAppliedPatch = nil
            if outcome.didWriteWorkspace {
                status = "Restored the previous bytes of \(outcome.proposal.relativePath)"
                await recordPatchEvent(outcome.proposal, kind: "patch.undone", summary: "User restored previous bytes of \(outcome.proposal.relativePath)")
            } else {
                errorMessage = "Undo refused a changed file; no bytes were overwritten."
                await recordPatchEvent(outcome.proposal, kind: "patch.undo_refused", summary: "Undo refused changed workspace bytes")
            }
        } catch {
            show(error)
        }
    }

    private func recordPatchEvent(_ proposal: NativePatchProposal, kind: String, summary: String) async {
        do {
            let runStore = try store ?? LocalRunStore()
            store = runStore
            _ = try await runStore.appendEvent(runID: proposal.runID, kind: kind, summary: summary)
            if let selectedConversationID { await refreshRunEvidence(conversationID: selectedConversationID, store: runStore) }
        } catch {
            errorMessage = "The project action completed, but local run evidence could not be updated: \(error.localizedDescription)"
        }
    }

    private func restoreWorkspace() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            selectedWorkspace = nil
            selectedPatchProject = nil
            patchPreview = nil
            lastAppliedPatch = nil
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
            guard !stale else {
                throw ScopedWorkspace.WorkspaceError.invalidFolder
            }
            let restoredWorkspace = try ScopedWorkspace(rootURL: url)
            let restoredPatchProject = try NativePatchProject(userSelectedFolderURL: url)
            if selectedPatchProject?.projectID != restoredPatchProject.projectID {
                patchPreview = nil
                lastAppliedPatch = nil
            }
            selectedWorkspace = restoredWorkspace
            selectedPatchProject = restoredPatchProject
            workspaceName = url.lastPathComponent
        } catch {
            // A revoked Files grant must be reselected by the user, not hidden.
            patchPreview = nil
            lastAppliedPatch = nil
            selectedWorkspace = nil
            selectedPatchProject = nil
            workspaceName = nil
            errorMessage = "The saved project folder is no longer available. Choose it again."
        }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func recordExtensionHook(_ event: HookEvent, runID: UUID, projectID: String?) {
        let registry = ExtensionRegistry()
        if let persistenceError = registry.persistenceError {
            errorMessage = "Run evidence was saved, but hook settings could not be read: \(persistenceError)"
            return
        }
        do {
            _ = try registry.record(event: event, runID: runID, projectID: projectID)
        } catch {
            errorMessage = "Run evidence was saved, but a local hook marker was not: \(error.localizedDescription)"
        }
    }
}
