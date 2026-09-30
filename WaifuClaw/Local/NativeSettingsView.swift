import SwiftUI

struct NativeSettingsView: View {
    @State private var modelDescription = "Not configured"
    @State private var storageError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("On-device storage")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Conversations and agent run events are kept in this app's local database. A selected Files project stays in its original folder. Model keys stay in the iPhone Keychain.")
                        .foregroundStyle(Theme.textSecondary)
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
        .background(Theme.background)
        .navigationTitle("Settings")
        .task { refresh() }
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
}
