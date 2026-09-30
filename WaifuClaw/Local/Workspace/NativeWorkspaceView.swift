import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NativeWorkspaceController {
    private static let bookmarkKey = "native.workspace.folderBookmark"

    private var workspace: WorkspaceEditor?
    private var undoRecord: WorkspaceUndoRecord?
    private var activeBookmark: Data?

    var workspaceName: String?
    var currentRelativePath = ""
    var directory = WorkspaceDirectory(relativePath: "", entries: [], isTruncated: false)
    var document: WorkspaceTextDocument?
    var draft = ""
    var errorMessage: String?
    var statusMessage = "Choose a folder in Files to begin."
    var showingFolderPicker = false
    var showingDiscardConfirmation = false

    private enum PendingAction {
        case open(WorkspaceEntry)
        case parent
        case closeDocument
        case chooseFolder
    }

    private var pendingAction: PendingAction?

    var hasUnsavedChanges: Bool {
        guard let document else { return false }
        return draft != document.originalText
    }

    var canSave: Bool {
        document != nil && hasUnsavedChanges
    }

    var canUndoLastSave: Bool {
        guard let document, let undoRecord else { return false }
        return document.relativePath == undoRecord.relativePath
    }

    init() {
        restoreWorkspaceBookmark()
    }

    func loadInitialDirectory() {
        guard workspace != nil else { return }
        reloadDirectory()
    }

    func refreshWorkspaceIfChanged() {
        let latestBookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        guard latestBookmark != activeBookmark else { return }
        if hasUnsavedChanges {
            errorMessage = "A different project was selected in Agent. Save or discard this draft before switching projects."
            return
        }
        document = nil
        draft = ""
        undoRecord = nil
        currentRelativePath = ""
        restoreWorkspaceBookmark()
        reloadDirectory()
    }

    func requestFolderPicker() {
        guardUnsavedChanges(before: .chooseFolder)
    }

    func selectFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let selectedWorkspace = try WorkspaceEditor(rootURL: url)
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)

            workspace = selectedWorkspace
            activeBookmark = bookmark
            workspaceName = url.lastPathComponent
            currentRelativePath = ""
            directory = WorkspaceDirectory(relativePath: "", entries: [], isTruncated: false)
            document = nil
            draft = ""
            undoRecord = nil
            errorMessage = nil
            statusMessage = "Selected \(url.lastPathComponent)."
            reloadDirectory()
        } catch {
            present(error)
        }
    }

    func presentPickerError(_ error: Error) {
        errorMessage = "Files could not select that folder: \(error.localizedDescription)"
        statusMessage = "Folder selection failed."
    }

    func requestOpen(_ entry: WorkspaceEntry) {
        guardUnsavedChanges(before: .open(entry))
    }

    func requestOpenParent() {
        guard !currentRelativePath.isEmpty else { return }
        guardUnsavedChanges(before: .parent)
    }

    func requestCloseDocument() {
        guard document != nil else { return }
        guardUnsavedChanges(before: .closeDocument)
    }

    func discardAndContinue() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        showingDiscardConfirmation = false
        clearOpenDocument()
        perform(action)
    }

    func cancelPendingNavigation() {
        pendingAction = nil
        showingDiscardConfirmation = false
    }

    func save() {
        guard let workspace, let document else { return }
        do {
            let result = try workspace.save(document: document, draft: draft)
            self.document = result.document
            undoRecord = result.undoRecord
            errorMessage = nil
            statusMessage = "Saved \(document.relativePath). You can undo this save while its content is unchanged."
        } catch {
            present(error)
        }
    }

    func undoLastSave() {
        guard let workspace, let undoRecord else { return }
        do {
            let reverted = try workspace.undoLastSave(undoRecord)
            document = reverted
            draft = reverted.originalText
            self.undoRecord = nil
            errorMessage = nil
            statusMessage = "Reverted the last save for \(reverted.relativePath)."
        } catch {
            present(error)
        }
    }

    private func restoreWorkspaceBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                errorMessage = "The saved workspace folder is no longer available. Choose it again in Files."
                statusMessage = "Saved folder access needs to be renewed."
                return
            }
            workspace = try WorkspaceEditor(rootURL: url)
            activeBookmark = bookmark
            workspaceName = url.lastPathComponent
            statusMessage = "Restored \(url.lastPathComponent)."
        } catch {
            errorMessage = "The saved workspace folder could not be opened. Choose it again in Files."
            statusMessage = "Saved folder access failed."
        }
    }

    private func guardUnsavedChanges(before action: PendingAction) {
        if hasUnsavedChanges {
            pendingAction = action
            showingDiscardConfirmation = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .chooseFolder:
            showingFolderPicker = true
        case .closeDocument:
            clearOpenDocument()
        case .parent:
            clearOpenDocument()
            currentRelativePath = currentRelativePath
                .split(separator: "/")
                .dropLast()
                .joined(separator: "/")
            reloadDirectory()
        case .open(let entry):
            if entry.isFolder {
                clearOpenDocument()
                currentRelativePath = entry.relativePath
                reloadDirectory()
            } else {
                openFile(entry)
            }
        }
    }

    private func openFile(_ entry: WorkspaceEntry) {
        guard let workspace else { return }
        do {
            let opened = try workspace.readText(relativePath: entry.relativePath)
            document = opened
            draft = opened.originalText
            errorMessage = nil
            statusMessage = "Opened \(entry.relativePath)."
        } catch {
            present(error)
        }
    }

    private func reloadDirectory() {
        guard let workspace else { return }
        do {
            directory = try workspace.listDirectory(relativePath: currentRelativePath)
            errorMessage = nil
            statusMessage = directory.isTruncated
                ? "Showing the first \(WorkspaceEditor.maximumEntriesPerDirectory) safe items in this folder."
                : "Showing \(directory.entries.count) item\(directory.entries.count == 1 ? "" : "s")."
        } catch {
            present(error)
        }
    }

    private func clearOpenDocument() {
        document = nil
        draft = ""
    }

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        statusMessage = "No changes were made."
    }
}

/// A user-controlled Files folder browser and UTF-8 text editor. It is safe to
/// mount directly in a `NavigationStack` or as an app tab.
public struct NativeWorkspaceView: View {
    @State private var controller = NativeWorkspaceController()

    public init() {}

    public var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 0) {
            workspaceHeader
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.12))
            }

            if controller.workspaceName == nil {
                emptyWorkspace
            } else if controller.document != nil {
                editor
            } else {
                browser
            }

            Text(controller.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Change folder", systemImage: "folder") {
                    controller.requestFolderPicker()
                }
            }
        }
        .fileImporter(
            isPresented: $controller.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    controller.selectFolder(folder)
                }
            case .failure(let error):
                controller.presentPickerError(error)
            }
        }
        .alert("Discard unsaved changes?", isPresented: $controller.showingDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                controller.discardAndContinue()
            }
            Button("Keep Editing", role: .cancel) {
                controller.cancelPendingNavigation()
            }
        } message: {
            Text("Your draft has not been saved. It will be discarded before changing folders or files.")
        }
        .task {
            controller.loadInitialDirectory()
        }
        .onAppear {
            controller.refreshWorkspaceIfChanged()
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.workspaceName ?? "No folder selected")
                    .font(.headline)
                if controller.workspaceName != nil {
                    Text(displayedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Only this folder is available to the browser and editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(controller.workspaceName == nil ? "Choose folder" : "Browse files") {
                if controller.workspaceName == nil {
                    controller.requestFolderPicker()
                } else if controller.document != nil {
                    controller.requestCloseDocument()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.thinMaterial)
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("Choose a Workspace Folder", systemImage: "folder.badge.plus")
        } description: {
            Text("Select a folder in Files. WaifuClaw will browse and edit only files inside that folder.")
        } actions: {
            Button("Choose Folder") {
                controller.requestFolderPicker()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browser: some View {
        List {
            if !controller.currentRelativePath.isEmpty {
                Button {
                    controller.requestOpenParent()
                } label: {
                    Label("Up one folder", systemImage: "arrow.turn.up.left")
                }
            }

            if controller.directory.isTruncated {
                Label(
                    "This folder has more than \(WorkspaceEditor.maximumEntriesPerDirectory) safe items. Only the first items are shown.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if controller.directory.entries.isEmpty {
                ContentUnavailableView(
                    "No visible files",
                    systemImage: "folder",
                    description: Text("Private metadata, credentials, symlink escapes, and unsupported items are not shown."))
            } else {
                ForEach(controller.directory.entries) { entry in
                    Button {
                        controller.requestOpen(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isFolder ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.isFolder ? Theme.magenta : Theme.textSecondary)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            if entry.isFolder {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .accessibilityLabel(entry.isFolder ? "Folder \(entry.name)" : "File \(entry.name)")
                }
            }
        }
        .listStyle(.plain)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Files", systemImage: "chevron.left") {
                    controller.requestCloseDocument()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Undo Last Save") {
                    controller.undoLastSave()
                }
                .buttonStyle(.bordered)
                .disabled(!controller.canUndoLastSave)
                Button("Save") {
                    controller.save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canSave)
            }
            .padding()

            TextEditor(text: draftBinding)
                .font(.body.monospaced())
                .padding(.horizontal, 8)
                .frame(minHeight: 220)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.25))
                }
                .padding(.horizontal)
                .accessibilityLabel("UTF-8 text draft")

            Divider().padding(.top, 12)
            diffPreview
        }
    }

    private var diffPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Original vs. Draft")
                    .font(.headline)
                Spacer()
                if controller.hasUnsavedChanges {
                    Text("Unsaved")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)

            if controller.diffLines.isEmpty {
                Text("No draft changes to save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.diffLines) { line in
                            Text("\(diffPrefix(for: line.kind))\(line.text)")
                                .font(.caption.monospaced())
                                .foregroundStyle(diffColor(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var displayedPath: String {
        controller.currentRelativePath.isEmpty ? "Selected folder" : controller.currentRelativePath
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { controller.draft },
            set: { controller.draft = $0 }
        )
    }

    private func diffPrefix(for kind: WorkspaceLineDiff.Kind) -> String {
        switch kind {
        case .context: return "  "
        case .removed: return "− "
        case .added: return "+ "
        case .notice: return "! "
        }
    }

    private func diffColor(for kind: WorkspaceLineDiff.Kind) -> Color {
        switch kind {
        case .context: return .secondary
        case .removed: return .red
        case .added: return .green
        case .notice: return .orange
        }
    }
}

private extension NativeWorkspaceController {
    var diffLines: [WorkspaceLineDiff.Line] {
        guard let document else { return [] }
        return WorkspaceLineDiff.make(original: document.originalText, draft: draft)
    }
}
