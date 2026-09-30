import SwiftUI

struct NativeSettingsView: View {
    @AppStorage(OnboardingKeys.displayName) private var displayName = ""
    @State private var modelDescription = "Not configured"
    @State private var storageError: String?
    @State private var storageNotice: String?
    @State private var showingHistoryDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    TextField("Display name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Display name")
                    Text("Saved on this phone for the Home greeting.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .themeCard()

                NavigationLink {
                    NativeConnectionsView()
                } label: {
                    Label("Connections & Permissions", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.magenta)
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    StudioEyebrow(title: "Studio companions")
                    Text("Kline, Rei and Sage are individually articulated 2D visual guides. Choosing one changes the art, not your model, permissions or agent capabilities.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        ScrollView { NativeCompanionChooserView().padding() }
                            .background { StudioBackdrop() }
                            .navigationTitle("Companions")
                    } label: {
                        Label("Choose animated companion", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .foregroundStyle(Theme.magentaSoft)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Agent model")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(modelDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        NativeModelSettingsView()
                    } label: {
                        Label("Model & API Key", systemImage: "key.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(Theme.magenta)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Optional decisions")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Jev is an optional typed routing check, not a coding model. It has a separate user-provided key and is off by default.")
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        JevSettingsView()
                    } label: {
                        Label("Jev Decisions", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(Theme.magenta)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Extensions & hooks")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Import declarative third-party manifests and enable local run activity. GitHub Markdown can be called manually after exact request review; other actions remain registration-only. No downloaded code executes.")
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        NativeExtensionsView()
                    } label: {
                        Label("Manage extensions & hooks", systemImage: "puzzlepiece.extension")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(Theme.magenta)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    StudioEyebrow(title: "Model Context Protocol")
                    Text("Connect public HTTPS MCP servers, inspect their real tool catalogs, and approve the exact JSON before any manual tool call. Optional bearer credentials stay in Keychain. OAuth-only and locally executable servers are not supported yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        NativeMCPView()
                    } label: {
                        Label("Manage MCP servers", systemImage: "network")
                    }
                    .foregroundStyle(Theme.magentaSoft)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    StudioEyebrow(title: "Project Guardian")
                    Text("Compare a user-selected project's real on-device file hashes against a baseline you approve. Manual only: no build, tests, model analysis or automatic background scan is claimed.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        NativeGuardianView()
                    } label: {
                        Label("Open Project Guardian", systemImage: "shield.lefthalf.filled")
                    }
                    .foregroundStyle(Theme.magentaSoft)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    StudioEyebrow(title: "Membership")
                    Text("Pro is not on sale yet. Core agent, Git, memory and companions remain usable without a subscription; no price or checkout is shown until a real ongoing service and App Store products are ready.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        NativeSubscriptionStorefrontView()
                    } label: {
                        Label("Membership & Pro status", systemImage: "sparkles")
                    }
                    .foregroundStyle(Theme.magentaSoft)
                }
                .themeCard()

                NavigationLink {
                    NativeNoticesView()
                } label: {
                    Label("Third-party notices", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.magenta)
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("On-device storage")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Conversations and agent run events are kept in this app's local database. A selected Files project stays in its original folder. Model keys stay in the iPhone Keychain.")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Delete all local conversations and runs", role: .destructive) {
                        showingHistoryDeletion = true
                    }
                    .font(.subheadline.bold())
                    if let storageNotice {
                        Text(storageNotice)
                            .foregroundStyle(Theme.success)
                    }
                    if let storageError {
                        Text(storageError)
                            .foregroundStyle(Theme.danger)
                    }
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("About WaifuClaw")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Native iPhone agent · no desktop pairing required")
                        .foregroundStyle(Theme.textSecondary)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .themeCard()
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Settings")
        .onAppear(perform: refresh)
        .alert("Delete all local conversation history?", isPresented: $showingHistoryDeletion) {
            Button("Delete conversations and runs", role: .destructive) {
                Task { await clearLocalHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes this phone's conversations, messages, run records and event evidence. It does not erase saved model keys, project files, or separately approved project memories.")
        }
    }

    private func refresh() {
        do {
            let configured = try LocalModelPreferences.load()
            let hasKey = try KeychainStore.agentKey() != nil
            modelDescription = hasKey
                ? "\(configured.model) · \(configured.endpoint.host ?? "HTTPS provider") · key stored on this phone"
                : "Model chosen, but no provider key is saved."
            storageError = nil
        } catch is LocalModelConfigurationError {
            modelDescription = "Not configured. Choose a model and add your own provider key."
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func clearLocalHistory() async {
        do {
            let store = try LocalRunStore()
            let count = try await store.deleteAllConversations()
            storageNotice = "Deleted \(count) local conversation\(count == 1 ? "" : "s") and their run evidence."
            storageError = nil
        } catch {
            storageNotice = nil
            storageError = "Could not delete local history: \(error.localizedDescription)"
        }
    }
}
