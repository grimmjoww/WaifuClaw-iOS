import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NativeMemoryController {
    private static let folderBookmarkKey = "native.workspace.folderBookmark"
    private let store: LocalNeuralMemoryStore?

    var projectID: String?
    var projectName: String?
    var facts: [LocalMemoryFact] = []
    var recalled: [LocalMemoryRecallResult] = []
    var factDraft = ""
    var searchDraft = ""
    var exportURL: URL?
    var status = "Choose a project folder to keep memories separate."
    var errorMessage: String?
    var showingFolderPicker = false
    var showingCaptureConfirmation = false
    var showingPurgeConfirmation = false
    var pendingDelete: LocalMemoryFact?

    init() {
        do {
            store = try LocalNeuralMemoryStore()
        } catch {
            store = nil
            errorMessage = "The on-device memory database could not be opened: \(error.localizedDescription)"
        }
    }

    func refreshProject() async {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.folderBookmarkKey) else {
            projectID = nil
            projectName = nil
            facts = []
            recalled = []
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                projectID = nil
                projectName = nil
                status = "The saved project folder needs access renewed in Files."
                return
            }
            let identity = NativeProjectIdentity.id(for: url)
            if identity != projectID {
                facts = []
                recalled = []
                exportURL = nil
            }
            projectID = identity
            projectName = url.lastPathComponent
            await reload()
        } catch {
            projectID = nil
            projectName = nil
            errorMessage = "The saved project folder is unavailable. Choose it again in Files."
        }
    }

    func selectFolder(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try WorkspaceEditor(rootURL: url)
            let bookmark = try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.folderBookmarkKey)
            await refreshProject()
        } catch {
            report(error)
        }
    }

    func reload() async {
        guard let store, let projectID else { return }
        do {
            facts = try await store.memories(in: projectID)
            errorMessage = nil
            status = "\(facts.count) approved project memor\(facts.count == 1 ? "y" : "ies") stored on this iPhone."
        } catch {
            report(error)
        }
    }

    func recall() async {
        guard let store, let projectID else { return }
        do {
            recalled = try await store.recall(projectID: projectID, query: searchDraft)
            errorMessage = nil
            status = "\(recalled.count) project memory result\(recalled.count == 1 ? "" : "s") found."
        } catch {
            report(error)
        }
    }

    func captureApprovedFact() async {
        guard let store, let projectID else { return }
        let fact = factDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        do {
            let request = LocalMemoryCaptureRequest(
                projectID: projectID,
                fact: fact,
                source: LocalMemorySource(kind: .manualNote, label: "Memory editor"),
                provenance: LocalMemoryProvenance(capturedBy: "user", approvalNote: "Approved in Memory")
            )
            _ = try await store.capture(request, approval: .userApproved)
            factDraft = ""
            recalled = []
            await reload()
            status = "Approved memory saved on this iPhone."
        } catch {
            report(error)
        }
    }

    func delete(_ fact: LocalMemoryFact) async {
        guard let store, let projectID else { return }
        do {
            try await store.deleteMemory(id: fact.id, projectID: projectID)
            recalled.removeAll { $0.id == fact.id }
            await reload()
            status = "One project memory deleted."
        } catch {
            report(error)
        }
    }

    func purgeCurrentProject() async {
        guard let store, let projectID else { return }
        do {
            try await store.purgeProject(projectID)
            facts = []
            recalled = []
            exportURL = nil
            errorMessage = nil
            status = "All approved memories for this project were deleted. Other projects were not touched."
        } catch {
            report(error)
        }
    }

    func prepareExport() async {
        guard let store, let projectID else { return }
        do {
            let data = try await store.exportJSON(forProject: projectID)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("WaifuClaw-Memory-\(projectID.prefix(12)).json")
            try data.write(to: destination, options: .atomic)
            exportURL = destination
            errorMessage = nil
            status = "Local JSON export prepared. Tap Share export and choose its destination."
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = "No memory change was made."
    }
}

struct NativeMemoryView: View {
    @State private var controller = NativeMemoryController()
    @State private var shareApprovedMemories = false
    private let memoryConsent = NativeMemoryConsent()

    var body: some View {
        @Bindable var controller = controller
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                projectCard
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.footnote)
                }
                if controller.projectID != nil {
                    privacyCard
                    captureCard
                    recallCard
                    storedCard
                    exportCard
                }
                Text(controller.status)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Choose project folder", systemImage: "folder") {
                    controller.showingFolderPicker = true
                }
            }
        }
        .onAppear {
            Task {
                await controller.refreshProject()
                refreshMemoryConsent()
            }
        }
        .onChange(of: controller.projectID) { _, _ in refreshMemoryConsent() }
        .fileImporter(
            isPresented: $controller.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    Task {
                        await controller.selectFolder(folder)
                        refreshMemoryConsent()
                    }
                }
            case .failure(let error):
                controller.errorMessage = "Files could not select that project: \(error.localizedDescription)"
            }
        }
        .alert("Save this exact fact to project memory?", isPresented: $controller.showingCaptureConfirmation) {
            Button("Save approved fact") { Task { await controller.captureApprovedFact() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(controller.factDraft.prefix(300)))
        }
        .alert("Delete all memories in this project?", isPresented: $controller.showingPurgeConfirmation) {
            Button("Delete all project memories", role: .destructive) {
                Task { await controller.purgeCurrentProject() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(controller.facts.count) approved memories for \(controller.projectName ?? "this project") only.")
        }
        .alert("Delete this approved memory?", isPresented: Binding(
            get: { controller.pendingDelete != nil },
            set: { if !$0 { controller.pendingDelete = nil } }
        )) {
            Button("Delete memory", role: .destructive) {
                if let fact = controller.pendingDelete {
                    Task { await controller.delete(fact) }
                }
                controller.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { controller.pendingDelete = nil }
        } message: {
            Text(String(controller.pendingDelete?.content.prefix(200) ?? ""))
        }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(controller.projectName ?? "No project folder selected", systemImage: "folder.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Facts, anchors and links remain on this iPhone and are isolated to the selected folder. No desktop, account or server is required.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button("Choose project folder") { controller.showingFolderPicker = true }
                .font(.subheadline.bold())
        }
        .themeCard()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model access to memory")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Toggle("Include relevant approved memories in agent requests", isOn: Binding(
                get: { shareApprovedMemories },
                set: { enabled in
                    memoryConsent.setEnabled(enabled, for: controller.projectID)
                    shareApprovedMemories = memoryConsent.isEnabled(for: controller.projectID)
                }
            ))
                .tint(Theme.magenta)
            Text(shareApprovedMemories
                ? "Up to three matching facts from this project may be sent to your configured model provider with an agent request. Their IDs will be recorded in local run evidence."
                : "Off. No saved memory facts are added to coding-model requests; you can still recall them here on-device.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private func refreshMemoryConsent() {
        shareApprovedMemories = memoryConsent.isEnabled(for: controller.projectID)
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remember a fact")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            TextEditor(text: Binding(
                get: { controller.factDraft },
                set: { controller.factDraft = $0 }
            ))
            .frame(height: 105)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Fact to remember")
            Button("Review and save fact") { controller.showingCaptureConfirmation = true }
                .themePrimaryButton()
                .disabled(controller.factDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Only the fact you confirm is saved. Conversations and project files are not captured automatically.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private var recallCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recall")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            TextField("Search this project's memories", text: Binding(
                get: { controller.searchDraft },
                set: { controller.searchDraft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Button("Recall related facts") { Task { await controller.recall() } }
                .disabled(controller.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(controller.recalled) { result in
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.storedFact).foregroundStyle(Theme.textPrimary)
                    Text("\(result.source.label) · score \(result.score, format: .number.precision(.fractionLength(2))) · hop \(result.hopCount)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(result.why)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
        .themeCard()
    }

    private var storedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approved facts (\(controller.facts.count))")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if controller.facts.isEmpty {
                Text("No approved facts yet.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(controller.facts) { fact in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.content).foregroundStyle(Theme.textPrimary)
                        Text("\(fact.source.label) · \(fact.createdAt, style: .date)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Button("Delete memory", systemImage: "trash", role: .destructive) {
                        controller.pendingDelete = fact
                    }
                    .labelStyle(.iconOnly)
                }
                Divider()
            }
            if !controller.facts.isEmpty {
                Button("Delete all project memories", role: .destructive) {
                    controller.showingPurgeConfirmation = true
                }
                .font(.footnote)
            }
        }
        .themeCard()
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Button("Prepare local memory JSON") { Task { await controller.prepareExport() } }
            if let exportURL = controller.exportURL {
                ShareLink(item: exportURL) {
                    Label("Share export", systemImage: "square.and.arrow.up")
                }
            }
            Text("An export contains this project's fact texts and provenance. It stays local until you select where to share it.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }
}
