import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NativeGitController {
    var cloneURL = ""
    var destinationName = ""
    var cloneLocation: NativeGitCloneLocation = .appSupport
    var clones: [NativeGitCloneRecord] = []
    var selectedCloneID: UUID?
    var states: [UUID: NativeGitRepositoryState] = [:]
    var isWorking = false
    var progress: NativeGitTransferProgress?
    var statusMessage = "Public HTTPS repositories can be cloned on this iPhone."
    var errorMessage: String?
    var workspaceFolderName: String?
    var showingFolderPicker = false
    var showingPullConfirmation = false

    private var service: NativeGitService?

    var selectedClone: NativeGitCloneRecord? {
        guard let selectedCloneID else { return nil }
        return clones.first(where: { $0.id == selectedCloneID })
    }

    var selectedState: NativeGitRepositoryState? {
        guard let selectedCloneID else { return nil }
        return states[selectedCloneID]
    }

    init() {
        do {
            let service = try NativeGitService()
            self.service = service
            clones = try service.listClones()
            selectedCloneID = clones.first?.id
            restoreWorkspaceFolderName()
        } catch {
            show(error)
        }
    }

    func load() {
        reloadClones()
        refreshSelected()
    }

    func suggestDestinationName() {
        guard let remote = try? NativeGitURLValidator.validatedRemoteURL(cloneURL) else { return }
        destinationName = NativeGitDestinationValidator.suggestedDirectoryName(for: remote)
    }

    func chooseWorkspaceFolder(_ url: URL) {
        guard let service else { return }
        do {
            try service.selectWorkspaceFolder(url)
            workspaceFolderName = url.lastPathComponent
            errorMessage = nil
            statusMessage = "Selected \(url.lastPathComponent) in Files. Git clones placed there remain in that folder."
        } catch {
            show(error)
        }
    }

    func presentFolderPickerError(_ error: Error) {
        errorMessage = "Files could not select that folder: \(error.localizedDescription)"
        statusMessage = "Folder selection failed."
    }

    func clone() {
        guard let service, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        progress = nil
        statusMessage = "Starting a safe libgit2 clone…"
        let remote = cloneURL
        let folder = destinationName
        let location = cloneLocation

        Task {
            do {
                let record = try await service.clone(
                    remoteText: remote,
                    directoryName: folder,
                    location: location
                ) { [weak self] update in
                    Task { @MainActor in
                        self?.progress = update
                        if let fraction = update.fractionCompleted {
                            self?.statusMessage = "Cloning… \(Int(fraction * 100))% · \(update.receivedObjects)/\(update.totalObjects) objects"
                        } else {
                            self?.statusMessage = "Cloning… \(update.receivedObjects) objects received"
                        }
                    }
                }
                clones = try service.listClones()
                selectedCloneID = record.id
                progress = nil
                statusMessage = "Cloned \(record.directoryName). No credentials, hooks, submodules, or LFS command were used."
                refreshSelected()
            } catch is CancellationError {
                progress = nil
                statusMessage = "Clone cancelled. Any partial destination was removed."
            } catch {
                progress = nil
                show(error)
                statusMessage = "Clone did not complete. No existing folder was overwritten."
            }
            isWorking = false
        }
    }

    func select(_ record: NativeGitCloneRecord) {
        guard !isWorking else { return }
        selectedCloneID = record.id
        refreshSelected()
    }

    func useSelectedCloneAsProject() {
        guard let service, let selectedClone, !isWorking else { return }
        do {
            try service.useCloneAsActiveProject(selectedClone)
            errorMessage = nil
            statusMessage = "\(selectedClone.directoryName) is now the active local project. Open Agent or Workspace to inspect it."
        } catch {
            show(error)
        }
    }

    func refreshSelected() {
        guard let service, let selectedClone else { return }
        do {
            states[selectedClone.id] = try service.inspect(selectedClone)
            errorMessage = nil
            statusMessage = "Read repository status locally."
        } catch {
            states.removeValue(forKey: selectedClone.id)
            show(error)
        }
    }

    func fetchSelected() {
        guard let service, let selectedClone, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Fetching refs only; your worktree will not change."
        Task {
            do {
                states[selectedClone.id] = try await service.fetch(selectedClone)
                statusMessage = "Fetched refs. The worktree was not changed."
            } catch {
                show(error)
                statusMessage = "Fetch failed; the worktree was not changed."
            }
            isWorking = false
        }
    }

    func requestPullSelected() {
        guard selectedClone != nil, !isWorking else { return }
        showingPullConfirmation = true
    }

    func pullSelectedAfterConfirmation() {
        guard let service, let selectedClone, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Fetching and proving a clean fast-forward…"
        Task {
            do {
                states[selectedClone.id] = try await service.pullFastForward(selectedClone)
                statusMessage = "Fast-forward complete. No merge, reset, or force checkout was used."
            } catch {
                show(error)
                statusMessage = "Pull was refused or failed. Local files were not force-overwritten."
            }
            isWorking = false
        }
    }

    private func reloadClones() {
        guard let service else { return }
        do {
            clones = try service.listClones()
            if selectedCloneID == nil || !clones.contains(where: { $0.id == selectedCloneID }) {
                selectedCloneID = clones.first?.id
            }
        } catch {
            show(error)
        }
    }

    private func restoreWorkspaceFolderName() {
        guard let bookmark = UserDefaults.standard.data(forKey: NativeGitService.workspaceBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return }
        workspaceFolderName = url.lastPathComponent
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A phone-local Git client powered by SwiftGitX and libgit2. This initial slice
/// supports anonymous public HTTPS clones, fetch, and clean fast-forward updates;
/// private-repository authentication is intentionally not implemented yet.
public struct NativeGitView: View {
    @State private var controller = NativeGitController()

    public init() {}

    public var body: some View {
        @Bindable var controller = controller

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cloneCard
                securityNotice
                cloneList
                selectedRepository
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(controller.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Git")
        .fileImporter(
            isPresented: $controller.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { controller.chooseWorkspaceFolder(url) }
            case .failure(let error):
                controller.presentFolderPickerError(error)
            }
        }
        .alert("Fast-forward this worktree?", isPresented: $controller.showingPullConfirmation) {
            Button("Fast-forward", role: .destructive) {
                controller.pullSelectedAfterConfirmation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WaifuClaw will fetch, then change files only if the worktree is clean and the checked-out branch can be proven to move forward without a merge. It will never hard reset, force-checkout, or overwrite dirty files.")
        }
        .task { controller.load() }
    }

    private var cloneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioEyebrow(title: "Project / source control")
            Label("Clone a repository", systemImage: "arrow.down.to.line.compact")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            TextField("https://host/owner/repository.git", text: $controller.cloneURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Public HTTPS Git repository URL")
                .onChange(of: controller.cloneURL) { _, _ in
                    if controller.destinationName.isEmpty { controller.suggestDestinationName() }
                }

            HStack(spacing: 8) {
                TextField("Destination folder", text: $controller.destinationName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Clone destination folder name")
                Button("Suggest") { controller.suggestDestinationName() }
                    .buttonStyle(.bordered)
            }

            Picker("Clone location", selection: $controller.cloneLocation) {
                Text("App storage").tag(NativeGitCloneLocation.appSupport)
                Text("Selected Files folder").tag(NativeGitCloneLocation.workspaceFolder)
            }
            .pickerStyle(.segmented)

            if controller.cloneLocation == .workspaceFolder {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.workspaceFolderName ?? "No Files folder selected")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Uses the shared workspace folder permission.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(controller.workspaceFolderName == nil ? "Choose folder" : "Change") {
                        controller.showingFolderPicker = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            if let progress = controller.progress {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                        Text("\(progress.receivedObjects) of \(progress.totalObjects) objects · \(byteCount(progress.receivedBytes))")
                    } else {
                        ProgressView()
                        Text("\(progress.receivedObjects) objects · \(byteCount(progress.receivedBytes))")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }

            Button {
                controller.clone()
            } label: {
                Label(controller.isWorking ? "Working…" : "Clone on this iPhone", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isWorking || controller.cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (controller.cloneLocation == .workspaceFolder && controller.workspaceFolderName == nil))
        }
        .themeCard()
    }

    private var securityNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Public HTTPS only", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Private repository authentication is not yet supported. WaifuClaw does not ask for, store, or send a token, SSH key, password, credential helper, Git hook, submodule command, or LFS binary.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("Clone size guard: 250,000 objects or 300 MB received. A clone that exceeds the guard is discarded before it is listed.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private var cloneList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clones on this iPhone")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if controller.clones.isEmpty {
                Text("No repositories have been cloned yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(controller.clones) { record in
                    Button {
                        controller.select(record)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: record.id == controller.selectedCloneID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(record.id == controller.selectedCloneID ? Theme.magenta : Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.directoryName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(record.remoteURL)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(record.location == .appSupport ? "App" : "Files")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }
        }
        .themeCard()
    }

    @ViewBuilder
    private var selectedRepository: some View {
        if let record = controller.selectedClone {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.directoryName)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(record.remoteURL)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        controller.refreshSelected()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isWorking)
                }

                if let state = controller.selectedState {
                    repositoryState(state)
                } else {
                    Text("Status unavailable. Refresh after renewing Files access or checking this clone exists.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack {
                    Button("Fetch", systemImage: "arrow.down.circle") {
                        controller.fetchSelected()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isWorking)
                    Button("Pull", systemImage: "arrow.down.to.line.compact") {
                        controller.requestPullSelected()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isWorking)
                }

                Button {
                    controller.useSelectedCloneAsProject()
                } label: {
                    Label("Use this clone in Agent & Workspace", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .disabled(controller.isWorking)

                Text("Fetch downloads refs only. Pull is confirmed and is limited to a clean, proven fast-forward on the current tracking branch.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .themeCard()
        }
    }

    private func repositoryState(_ state: NativeGitRepositoryState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("Branch", value: state.branch)
            LabeledContent("HEAD", value: state.head)
            LabeledContent("Upstream", value: state.upstream ?? "None")
            HStack {
                Text("Worktree")
                Spacer()
                Text(state.isDirty ? "Dirty (\(state.dirtyEntries))" : "Clean")
                    .foregroundStyle(state.isDirty ? Theme.danger : .green)
            }
            HStack {
                Text("Relationship")
                Spacer()
                Text(relationshipLabel(state.relationship))
                    .foregroundStyle(relationshipColor(state.relationship))
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func relationshipLabel(_ relationship: NativeGitRepositoryState.Relationship) -> String {
        switch relationship {
        case .unknown: "Unknown"
        case .upToDate: "Up to date"
        case .behind: "Behind upstream"
        case .ahead: "Ahead of upstream"
        case .diverged: "Diverged"
        case .noUpstream: "No upstream"
        case .detached: "Detached HEAD"
        }
    }

    private func relationshipColor(_ relationship: NativeGitRepositoryState.Relationship) -> Color {
        switch relationship {
        case .upToDate: .green
        case .behind: .orange
        case .unknown, .ahead, .diverged, .noUpstream, .detached: Theme.danger
        }
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
