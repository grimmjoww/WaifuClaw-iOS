import SwiftUI
import UniformTypeIdentifiers

/// Management UI for locally registered, declarative extension manifests.
/// Importing a manifest registers metadata only: WaifuClaw does not download or
/// run plugin code, and this screen does not invoke plugin endpoints.
@MainActor
struct NativeExtensionsView: View {
    @StateObject private var registry: ExtensionRegistry
    @State private var showingImporter = false
    @State private var operationError: String?
    @State private var selectedProjectID: String?

    init(registry: ExtensionRegistry? = nil) {
        _registry = StateObject(wrappedValue: registry ?? ExtensionRegistry())
    }

    var body: some View {
        List {
            Section {
                Text("Import a JSON manifest that describes a vendor, a public HTTPS endpoint, and bounded action metadata. Importing registers data only; it never runs downloaded code or contacts the endpoint.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    showingImporter = true
                } label: {
                    Label("Import manifest from Files", systemImage: "square.and.arrow.down")
                }
                .accessibilityHint("Choose a JSON extension manifest. No scripts or code are imported.")
            } header: {
                Text("Declarative extensions")
            }

            Section {
                if registry.installedExtensions.isEmpty {
                    ContentUnavailableView(
                        "No extensions installed",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Import a vendor manifest when you need its declared action metadata.")
                    )
                } else {
                    ForEach(registry.installedExtensions) { plugin in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(plugin.manifest.name)
                                        .font(.headline)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(plugin.manifest.vendor) · \(plugin.manifest.id)")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Text(plugin.isEnabled ? "Enabled" : "Disabled")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(plugin.isEnabled ? Theme.magenta : Theme.textSecondary)
                            }

                            Text(plugin.manifest.baseEndpoint.absoluteString)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .textSelection(.enabled)

                            Text("\(plugin.manifest.actions.count) declared action\(plugin.manifest.actions.count == 1 ? "" : "s") · registration only")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)

                            Toggle("Enable registration", isOn: pluginEnabledBinding(for: plugin.id))
                                .tint(Theme.magenta)

                            Button("Remove extension", role: .destructive) {
                                remove(plugin.id)
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Enabled means the manifest’s declared metadata is available to the app. This version has no HTTP plugin invocation API.")
            }

            Section {
                ForEach(HookEvent.allCases) { event in
                    Toggle(event.displayName, isOn: hookEnabledBinding(for: event))
                        .tint(Theme.magenta)
                }
                Text("When WaifuClaw receives a real terminal run event while this app is active, an enabled rule adds a local activity marker. It does not call a plugin, use the network, or start an always-on service.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } header: {
                Text("Local run hooks")
            } footer: {
                Text("Only “create local activity marker” is available in this release.")
            }

            Section {
                if registry.activities(forProjectID: selectedProjectID).isEmpty {
                    ContentUnavailableView(
                        "No activity markers",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Enable a local run hook to record future finished or failed runs for the selected project.")
                    )
                } else {
                    ForEach(registry.activities(forProjectID: selectedProjectID)) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.event.displayName)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(activity.message)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            if let projectID = activity.projectID {
                                Text("Project \(projectID.prefix(12))")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Text("No project was attached to this run.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Text(activity.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                Text("Local activity")
            }

            if let persistenceError = registry.persistenceError {
                Section {
                    Text(persistenceError)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                } header: {
                    Text("Storage needs attention")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Extensions")
        .onAppear {
            registry.reloadFromDisk()
            refreshProjectIdentity()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try registry.importManifest(fromFileURL: url)
                } catch {
                    operationError = error.localizedDescription
                }
            case .failure(let error):
                operationError = error.localizedDescription
            }
        }
        .alert(
            "Extension operation could not be completed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
    }

    private func pluginEnabledBinding(for pluginID: String) -> Binding<Bool> {
        Binding(
            get: { registry.installedExtensions.first(where: { $0.id == pluginID })?.isEnabled ?? false },
            set: { isEnabled in
                do {
                    try registry.setExtensionEnabled(pluginID, isEnabled: isEnabled)
                } catch {
                    operationError = error.localizedDescription
                }
            }
        )
    }

    private func hookEnabledBinding(for event: HookEvent) -> Binding<Bool> {
        Binding(
            get: { registry.hookRule(for: event).isEnabled },
            set: { isEnabled in
                do {
                    try registry.setHookEnabled(event, isEnabled: isEnabled)
                } catch {
                    operationError = error.localizedDescription
                }
            }
        )
    }

    private func remove(_ pluginID: String) {
        do {
            try registry.removeExtension(pluginID)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func refreshProjectIdentity() {
        guard let bookmark = UserDefaults.standard.data(forKey: "native.workspace.folderBookmark") else {
            selectedProjectID = nil
            return
        }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [], relativeTo: nil, bookmarkDataIsStale: &stale
        ), !stale {
            selectedProjectID = NativeProjectIdentity.id(for: url)
        } else {
            selectedProjectID = nil
        }
    }
}
