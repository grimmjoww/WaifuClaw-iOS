import SwiftUI

/// Settings → API Key: the free-tier BYOK surface.
/// Provider picker, key entry with validate-on-save, status, delete/rotate.
/// The key lives in the Keychain; it is validated live against the provider
/// and forwarded to the paired computer over the pinned device channel.
struct BYOKSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewModel: BYOKViewModel

    init(viewModel: BYOKViewModel = BYOKViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    if let notice = viewModel.notice {
                        BYOKNoticeBanner(message: notice, isError: viewModel.noticeIsError) {
                            viewModel.notice = nil
                        }
                    }
                    statusCard
                    setupCard
                    explainerCard
                }
                .padding()
            }
            .refreshable { await viewModel.refreshStatus(api: appState.api) }
        }
        .navigationTitle("API Key")
        .task { await viewModel.refreshStatus(api: appState.api) }
        .confirmationDialog(
            "Delete this API key?",
            isPresented: $viewModel.confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete key", role: .destructive) {
                viewModel.deleteTapped(api: appState.api)
            }
        } message: {
            Text("The key is removed from this phone and your computer. The agent will use your computer's own model until you add a new key.")
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(statusText)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if viewModel.statusLoading {
                    ProgressView().tint(Theme.magenta)
                }
            }
            if let validated = viewModel.status?.lastValidatedDate {
                Text("Last checked \(validated, format: .dateTime.day().month().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if viewModel.status?.configured == true {
                Button("Delete key", role: .destructive) {
                    viewModel.confirmingDelete = true
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .themeCard()
    }

    private var statusColor: Color {
        guard let status = viewModel.status, status.configured else { return Theme.textSecondary }
        return status.active == true ? Theme.success : Theme.warning
    }

    private var statusText: String {
        guard let status = viewModel.status, status.configured else { return "No key saved" }
        let providerName = status.providerEnum?.displayName ?? status.provider ?? "Unknown"
        let model = status.model.map { " · \($0)" } ?? ""
        if status.active == true {
            return "Active · \(providerName)\(model)"
        }
        return "Saved, but failing — re-check the key · \(providerName)\(model)"
    }

    // MARK: - Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.status?.configured == true ? "Rotate key" : "Add key")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Picker("Provider", selection: $viewModel.provider) {
                ForEach(BYOKProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            keyField
            if viewModel.provider.requiresBaseURL {
                TextField("Base URL (https://…)", text: $viewModel.baseURLInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(
                "Model (optional\(viewModel.provider.defaultModel.map { ", default \($0)" } ?? ""))",
                text: $viewModel.modelInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            if let hint = viewModel.keyHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            switch viewModel.phase {
            case .idle:
                EmptyView()
            case .checkingKey, .syncing:
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.magenta)
                    Text(
                        viewModel.phase == .checkingKey
                            ? "Checking key with \(viewModel.provider.displayName)…"
                            : "Syncing with your computer…"
                    )
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            Button("Save API key") { viewModel.saveTapped(api: appState.api) }
                .themePrimaryButton()
                .disabled(
                    viewModel.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.keyHint != nil || viewModel.isBusy
                )
        }
        .themeCard()
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            Group {
                if viewModel.revealKey {
                    TextField("sk-…", text: $viewModel.keyInput)
                } else {
                    SecureField("sk-…", text: $viewModel.keyInput)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            Button(
                viewModel.revealKey ? "Hide key" : "Show key",
                systemImage: viewModel.revealKey ? "eye.slash" : "eye"
            ) {
                viewModel.revealKey.toggle()
            }
            .labelStyle(.iconOnly)
        }
    }

    // MARK: - Explainer

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this works")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("The free tier runs the agent on your own provider key. The key is checked live with the provider, stored only in this phone's keychain, and sent to your computer over the secure pairing connection — nowhere else.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("No key? The agent uses whatever model your computer is already configured with.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }
}

// MARK: - Notice banner

/// Small same-concern helper (mirrors the license screen's banner pattern).
private struct BYOKNoticeBanner: View {
    let message: String
    let isError: Bool
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(message)
                .font(.footnote)
            Spacer()
            Button("Dismiss notice", systemImage: "xmark") { onDismiss() }
                .labelStyle(.iconOnly)
                .font(.caption)
        }
        .foregroundStyle(isError ? Theme.danger : Theme.success)
        .padding()
        .background((isError ? Theme.danger : Theme.success).opacity(0.12))
        .clipShape(.rect(cornerRadius: 14))
    }
}

// MARK: - Previews

#Preview("API key — empty") {
    NavigationStack {
        BYOKSettingsView()
    }
    .environmentObject(AppState())
}

#Preview("API key — configured") {
    NavigationStack {
        BYOKSettingsView(viewModel: .previewConfigured)
    }
    .environmentObject(AppState())
}
