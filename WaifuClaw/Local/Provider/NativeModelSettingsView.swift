import SwiftUI

/// The native provider is configured on the phone. The older BYOK screen is a
/// desktop-forwarding flow and must never be mounted in standalone mode.
struct NativeModelSettingsView: View {
    @State private var endpointText = LocalModelPreferences.defaultEndpoint
    @State private var modelText = ""
    @State private var keyInput = ""
    @State private var showKey = false
    @State private var hasSavedKey = false
    @State private var notice: String?
    @State private var isError = false
    @State private var confirmRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Model provider")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Choose an OpenAI-compatible HTTPS endpoint and its exact model ID. OpenAI uses the address shown below; other compatible providers may use a different URL.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Provider base URL", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Exact model ID", text: $modelText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Label(hasSavedKey ? "Key saved on this iPhone" : "No provider key saved", systemImage: hasSavedKey ? "checkmark.shield.fill" : "key")
                        .foregroundStyle(hasSavedKey ? Theme.success : Theme.warning)
                    HStack {
                        Group {
                            if showKey {
                                TextField("Provider API key", text: $keyInput)
                            } else {
                                SecureField("Provider API key", text: $keyInput)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        Button(showKey ? "Hide key" : "Show key", systemImage: showKey ? "eye.slash" : "eye") {
                            showKey.toggle()
                        }
                        .labelStyle(.iconOnly)
                    }
                    Text("Leave the key field blank to keep an existing key when changing only the model. Saving does not prove that a provider accepts the model; your first request will report any provider error.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Save provider settings", action: save)
                        .themePrimaryButton()
                    if hasSavedKey {
                        Button("Remove provider key", role: .destructive) {
                            confirmRemoval = true
                        }
                    }
                }
                .themeCard()

                if let notice {
                    Label(notice, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(isError ? Theme.danger : Theme.success)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Text("The coding agent runs on your phone. When you send a request, the selected provider receives your message and any project excerpts you authorize the agent to read. Your key is stored in this phone's Keychain and sent directly to your selected provider—not a WaifuClaw computer or server. Provider charges are separate from WaifuClaw Pro.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .themeCard()
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Model & API Key")
        .task { refresh() }
        .confirmationDialog("Remove this phone's provider key?", isPresented: $confirmRemoval) {
            Button("Remove key", role: .destructive, action: removeKey)
        } message: {
            Text("Local conversations remain. New agent requests will stop until you add a key again.")
        }
    }

    private func refresh() {
        endpointText = UserDefaults.standard.string(forKey: LocalModelPreferences.endpointKey)
            ?? LocalModelPreferences.defaultEndpoint
        modelText = UserDefaults.standard.string(forKey: LocalModelPreferences.modelKey) ?? ""
        do {
            hasSavedKey = try KeychainStore.agentKey() != nil
        } catch {
            showError(error)
        }
    }

    private func save() {
        do {
            let configuration = try LocalModelConfiguration(
                endpointText: endpointText,
                modelText: modelText
            )
            let newKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newKey.isEmpty {
                try KeychainStore.saveAgentKey(newKey)
            } else if try KeychainStore.agentKey() == nil {
                throw LocalModelConfigurationError.missingKey
            }
            LocalModelPreferences.save(configuration)
            keyInput = ""
            hasSavedKey = true
            isError = false
            notice = "Provider settings saved on this phone. Send a message to verify model access."
        } catch {
            showError(error)
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.deleteAgentKey()
            hasSavedKey = false
            keyInput = ""
            notice = "Provider key removed from this phone."
            isError = false
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        isError = true
        notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
