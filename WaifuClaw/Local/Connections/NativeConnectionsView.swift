import SwiftUI
import UniformTypeIdentifiers

/// No fake "connected" indicators: a saved key is configuration, not proof a
/// vendor accepted it. Live checks remain in the provider/Jev detail screens.
@MainActor
struct NativeConnectionsView: View {
    @StateObject private var extensionRegistry = ExtensionRegistry()
    @State private var selectedProjectName: String?
    @State private var selectedProjectID: String?
    @State private var shareApprovedMemory = false
    @State private var providerStatus = "Checking local configuration…"
    @State private var jevStatus = "Checking local configuration…"
    @State private var gitStatus = "Checking local repositories…"
    @State private var extensionsStatus = "Checking local registrations…"
    @State private var operationError: String?
    @State private var operationNotice: String?
    @State private var showingFolderPicker = false
    @State private var showingDisconnectConfirmation = false
    private let projectPermission = NativeProjectPermission()
    private let memoryConsent = NativeMemoryConsent()
    private let invocationClient = ExtensionInvocationClient()

    var body: some View {
        List {
            Section("Project files · iOS Files permission") {
                Label(selectedProjectName ?? "No folder selected", systemImage: "folder.badge.person.crop")
                Text("The Files picker grants this app access only to the folder you choose. Agent and Team read only under that folder; the model can receive authorized text when you run it. This is not access to your entire iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(selectedProjectName == nil ? "Choose project folder in Files" : "Change project folder in Files") {
                    showingFolderPicker = true
                }
                if selectedProjectName != nil {
                    Button("Forget this project folder", role: .destructive) {
                        showingDisconnectConfirmation = true
                    }
                }
                Text("To stop a currently running Agent or Team workflow, use its Stop control before changing or forgetting a folder. A change affects the next run; it never deletes project files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Your model · BYOK") {
                Label(providerStatus, systemImage: "key.fill")
                NavigationLink("Set up or test model connection") {
                    NativeModelSettingsView()
                }
                Text("The model key stays in Keychain. Prompts and file excerpts actually read by the agent go directly to your chosen HTTPS provider. A saved key alone does not prove the model works; use the live test in model settings. Provider usage may be billed separately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Jev · optional decision service") {
                Label(jevStatus, systemImage: "point.3.connected.trianglepath.dotted")
                NavigationLink("Set up or test Jev") {
                    JevSettingsView()
                }
                Text("Jev has a separate user key and is off by default. When enabled, a bounded decision request goes to TypeSafe; it cannot bypass an edit approval or replace your coding model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Git and external actions") {
                Label(gitStatus, systemImage: "arrow.triangle.branch")
                NavigationLink("Open Git clone, fetch and pull") {
                    NativeGitView()
                }
                Label(extensionsStatus, systemImage: "puzzlepiece.extension")
                NavigationLink("Manage extensions and local hooks") {
                    NativeExtensionsView()
                }
                Text("Git presently supports public HTTPS repositories; private Git credentials are not connected yet. Imported extension manifests do not execute code. Only the explicitly confirmed GitHub Markdown action can make a third-party request in this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("On-device memory consent") {
                Toggle("Send matching approved memories with agent requests", isOn: Binding(
                    get: { shareApprovedMemory },
                    set: { enabled in
                        memoryConsent.setEnabled(enabled, for: selectedProjectID)
                        shareApprovedMemory = memoryConsent.isEnabled(for: selectedProjectID)
                    }
                ))
                    .disabled(selectedProjectID == nil)
                Text(selectedProjectName == nil
                     ? "Select a project first. Memory sharing is off until you explicitly enable it."
                     : "When enabled, up to three approved facts from this project may be sent to your model with an Agent request. Saved memory stays on this phone; deleting or exporting facts is available in Memory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions not requested") {
                Text("Camera, microphone, notifications, local-network discovery and Face ID are not requested: no feature in this standalone build uses or enforces them. Web requests use system HTTPS; iOS does not provide a per-request internet-permission dialog.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let operationNotice {
                Section { Text(operationNotice).foregroundStyle(Theme.success) }
            }
            if let operationError {
                Section("Needs attention") { Text(operationError).foregroundStyle(Theme.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Connections & Permissions")
        .onAppear(perform: refresh)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    selectedProjectName = try projectPermission.selectFolder(url)
                    selectedProjectID = NativeProjectIdentity.id(for: url)
                    shareApprovedMemory = memoryConsent.isEnabled(for: selectedProjectID)
                    operationNotice = "Project folder selected for future Agent, Team, Workspace and Memory activity."
                    operationError = nil
                } catch {
                    operationError = "Files permission could not be saved: \(error.localizedDescription)"
                }
            case .failure(let error):
                operationError = "Files could not select the folder: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Forget access to this project?", isPresented: $showingDisconnectConfirmation) {
            Button("Forget project folder", role: .destructive) {
                memoryConsent.setEnabled(false, for: selectedProjectID)
                projectPermission.disconnectFolder()
                selectedProjectName = nil
                selectedProjectID = nil
                shareApprovedMemory = false
                operationNotice = "The saved project selection was removed. No project files were deleted. Stop any run already active in another tab separately."
                operationError = nil
            }
        } message: {
            Text("This removes WaifuClaw's saved Files bookmark for future runs. A currently active Agent or Team run retains its already opened folder until you stop it; this does not delete the folder or change iOS-wide Files access.")
        }
    }

    private func refresh() {
        do {
            let folder = try projectPermission.selectedFolder()
            selectedProjectName = folder?.lastPathComponent
            selectedProjectID = folder.map { NativeProjectIdentity.id(for: $0) }
            shareApprovedMemory = memoryConsent.isEnabled(for: selectedProjectID)
        } catch {
            selectedProjectName = nil
            selectedProjectID = nil
            shareApprovedMemory = false
            operationError = "Project folder needs re-selection: \(error.localizedDescription)"
        }
        do {
            let config = try LocalModelPreferences.load()
            providerStatus = try KeychainStore.agentKey() == nil
                ? "\(config.model) configured · API key missing"
                : "\(config.model) configured · key saved (live status not checked)"
        } catch is LocalModelConfigurationError {
            providerStatus = "Not configured"
        } catch {
            providerStatus = "Keychain unavailable; check model settings"
            operationError = error.localizedDescription
        }
        do {
            let keyPresent = try JevKeychainStore().load() != nil
            let enabled = JevDecisionPreferences().isDecisionOptedIn
            jevStatus = !keyPresent
                ? "No Jev key · no Jev calls"
                : enabled ? "Key saved · decisions enabled (live status not checked)" : "Key saved · decisions off"
        } catch {
            jevStatus = "Jev Keychain unavailable"
            operationError = error.localizedDescription
        }
        do {
            let count = try NativeGitService().listClones().count
            gitStatus = "Public HTTPS Git available · \(count) local clone\(count == 1 ? "" : "s")"
        } catch {
            gitStatus = "Git clone list unavailable"
            operationError = error.localizedDescription
        }
        extensionRegistry.reloadFromDisk()
        let enabled = extensionRegistry.installedExtensions.filter(\.isEnabled)
        let usable = enabled.filter { invocationClient.isInvocationSupported(for: $0.manifest) }
        extensionsStatus = "\(enabled.count) enabled declaration\(enabled.count == 1 ? "" : "s") · \(usable.count) supported manual GitHub action\(usable.count == 1 ? "" : "s")"
        if let error = extensionRegistry.persistenceError { operationError = error }
    }
}
