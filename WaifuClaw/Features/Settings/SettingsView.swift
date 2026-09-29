import SwiftUI

/// Settings tab: who we're paired with, connection health, reconnect/unpair,
/// and guidance for getting the desktop side working. Unpair is loud and
/// confirmed; reconnect shows its result via the connection banner.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var confirmingUnpair = false
    @State private var reconnecting = false
    @State private var editingName = false
    @State private var replayingIntro = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    profileCard
                    computerCard
                    connectionCard
                    apiKeyCard
                    guidanceCard
                    aboutCard
                }
                .padding()
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Unpair this phone?",
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { unpair() }
        } message: {
            Text("Your phone will forget this computer. You'll need to scan a new QR code to pair again.")
        }
        .sheet(isPresented: $editingName) {
            NavigationStack {
                DisplayNameView(onContinue: { editingName = false })
                    .navigationTitle("Display name")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $replayingIntro) {
            ReplayIntroView(onDone: { replayingIntro = false })
        }
    }

    // MARK: - Profile

    /// Display name, the intro guide replay, and the Memory/Pro destinations
    /// (they live here now instead of as tabs).
    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Button {
                editingName = true
            } label: {
                HStack {
                    Label("Change display name", systemImage: "person.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityHint("Change the name WaifuClaw calls you")
            Button {
                replayingIntro = true
            } label: {
                HStack {
                    Label("Replay intro guide", systemImage: "play.circle.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            NavigationLink {
                MemoryBrowserView()
            } label: {
                HStack {
                    Label("Memory", systemImage: "brain.head.profile")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            NavigationLink {
                LicenseView()
            } label: {
                HStack {
                    Label("Pro", systemImage: "sparkles")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .themeCard()
    }

    // MARK: - Paired computer

    private var computerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired computer")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if case .paired(let computer) = appState.pairing {
                LabeledValue(label: "Name", value: computer.deviceName)
                LabeledValue(label: "Address", value: "\(computer.host):\(computer.port)", mono: true)
                LabeledValue(
                    label: "Connection",
                    value: computer.kind == .tunnel ? "Secure tunnel" : "Local network"
                )
            } else {
                Text("Not paired.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .themeCard()
    }

    // MARK: - Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionText)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            Button(reconnecting ? "Reconnecting…" : "Reconnect") {
                reconnect()
            }
            .themePrimaryButton()
            .disabled(reconnecting)
            Button("Unpair this phone", role: .destructive) {
                confirmingUnpair = true
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .themeCard()
    }

    private var connectionColor: Color {
        switch appState.connection {
        case .connected: return Theme.success
        case .checking, .unknown: return Theme.textSecondary
        case .notConnected: return Theme.warning
        }
    }

    private var connectionText: String {
        switch appState.connection {
        case .connected(let kind):
            return kind == .tunnel ? "Connected via secure tunnel" : "Connected on local network"
        case .checking:
            return "Checking…"
        case .unknown:
            return "Unknown"
        case .notConnected(let message):
            return message
        }
    }

    private func reconnect() {
        reconnecting = true
        Task {
            await appState.refreshConnection()
            reconnecting = false
        }
    }

    private func unpair() {
        Task {
            await appState.unpair()
            // RootView routes back to the pairing flow — that IS the feedback.
        }
    }

    // MARK: - API Key (BYOK, free tier)

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Key")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("The free tier runs on your own provider key — OpenAI, Anthropic, and more.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            NavigationLink {
                BYOKSettingsView()
            } label: {
                HStack {
                    Label("Set up API key", systemImage: "key.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .themeCard()
    }

    // MARK: - Guidance

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting connected")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            GuidanceStep(
                number: "1",
                text: "On your computer, open WaifuClaw → Settings → Phone remote and turn it on."
            )
            GuidanceStep(
                number: "2",
                text: "Tap Pair phone and scan the QR code with this app."
            )
            GuidanceStep(
                number: "3",
                text: "Away from home? Install Tailscale on both devices and pair using your tailnet address — no QR rescan needed afterwards."
            )
            Text("If the app can't find your computer, make sure it's awake, WaifuClaw is running, and both devices are on the same network (or the same tailnet).")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            LabeledValue(label: "App", value: "WaifuClaw for iOS")
            LabeledValue(
                label: "Version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            )
        }
        .themeCard()
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .font(mono ? .body.monospaced() : .body)
        }
        .font(.subheadline)
    }
}

private struct GuidanceStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.magenta)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
