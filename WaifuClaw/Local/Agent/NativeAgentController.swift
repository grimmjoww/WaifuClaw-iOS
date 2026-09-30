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

    private var store: LocalRunStore?
    private var selectedWorkspace: ScopedWorkspace?
    private var activeTask: Task<Void, Never>?
    private static let bookmarkKey = "native.workspace.folderBookmark"

    init() {
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
            }
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
    }

    func selectConversation(_ id: UUID) async {
        guard !isRunning else { return }
        do { try await loadConversation(id) }
        catch { show(error) }
    }

    func selectWorkspace(_ url: URL) {
        do {
            let workspace = try ScopedWorkspace(rootURL: url)
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            selectedWorkspace = workspace
            workspaceName = url.lastPathComponent
            errorMessage = nil
            status = "Project selected: \(url.lastPathComponent)"
        } catch {
            show(error)
        }
    }

    func refreshWorkspace() {
        restoreWorkspace()
    }

    func send() {
        guard !isRunning else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isRunning = true
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
            let useJev = JevDecisionPreferences().isDecisionOptedIn
            let jevKey = useJev ? (try? JevKeychainStore().load()) : nil
            let useMemory = UserDefaults.standard.bool(forKey: "native.memory.useInAgent")
            let engine = NativeAgentEngine(store: store)
            for try await signal in await engine.stream(
                conversationID: conversationID,
                prompt: prompt,
                provider: provider,
                workspace: selectedWorkspace,
                jevEnabled: useJev,
                jevKey: jevKey,
                memoryEnabled: useMemory
            ) {
                switch signal {
                case .started(let id):
                    activeRunID = id
                    messages = try await store.messages(in: conversationID)
                    status = "Working on this iPhone…"
                case .text(let chunk):
                    streamedText += chunk
                case .toolActivity(let activity):
                    status = activity
                    await refreshRunEvidence(conversationID: conversationID, store: store)
                case .completed:
                    status = "Run completed and saved on this phone"
                    if let activeRunID {
                        recordExtensionHook(.runFinished, runID: activeRunID, projectID: runProjectID)
                    }
                }
            }
            messages = try await store.messages(in: conversationID)
            conversations = try await store.listConversations()
            await refreshRunEvidence(conversationID: conversationID, store: store)
            streamedText = ""
        } catch is CancellationError {
            status = "Run stopped on this phone"
        } catch {
            show(error)
            status = "Run failed"
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
    }

    private func refreshRunEvidence(conversationID: UUID, store: LocalRunStore) async {
        guard let last = try? await store.runs(in: conversationID).last else { return }
        recentEvents = (try? await store.events(in: last.id)) ?? []
    }

    private func restoreWorkspace() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { return }
            selectedWorkspace = try ScopedWorkspace(rootURL: url)
            workspaceName = url.lastPathComponent
        } catch {
            // A revoked Files grant must be reselected by the user, not hidden.
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
