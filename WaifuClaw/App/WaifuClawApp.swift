import SwiftUI

@main
struct WaifuClawApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    appState.restore()
                    appState.startWakePolling()
                }
                // Blocking TOFU-mismatch warning (audit §4) — full screen, no dismiss-by-tap.
                .fullScreenCover(item: $appState.securityAlert) { alert in
                    FingerprintMismatchView(alert: alert)
                        .environmentObject(appState)
                }
                // Revoked device (audit §2) — never a dead app, always a way back.
                .fullScreenCover(isPresented: $appState.showRevokedNotice) {
                    RevokedDeviceView()
                        .environmentObject(appState)
                }
        }
    }
}

/// First launch → onboarding; then pairing → the main tabs.
/// (The onboarding flow: intro pages → display name → iOS permission prompts,
/// like every app in history. OnboardingView writes hasCompletedOnboarding
/// itself when it finishes, which re-renders this gate.)
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(OnboardingKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !hasCompletedOnboarding {
                OnboardingView()
            } else {
                switch appState.pairing {
                case .unpaired:
                    PairingFlowView()
                case .paired:
                    MainTabView()
                }
            }
        }
        .tint(Theme.magenta)
    }
}

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.tabSelection) {
            NavigationStack {
                HomeTabView()
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(WCITab.home)

            NavigationStack {
                RunsTabView()
            }
            .tabItem { Label("Runs", systemImage: "play.circle.fill") }
            .tag(WCITab.runs)

            NavigationStack {
                TeamTabView()
            }
            .tabItem { Label("Team", systemImage: "person.2.fill") }
            .tag(WCITab.team)

            NavigationStack {
                ThreadListView()
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(WCITab.chat)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(WCITab.settings)
        }
        .safeAreaInset(edge: .top) {
            ConnectionStatusBanner()
        }
    }
}

/// "This phone was unpaired from your computer" + Pair again (audit §2).
struct RevokedDeviceView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.warning)
                Text("Phone unpaired")
                    .font(.title.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text("This phone was unpaired from your computer. Pair again to reconnect.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal)
                Button("Pair again") {
                    Task {
                        appState.showRevokedNotice = false
                        await appState.unpair()
                    }
                }
                .themePrimaryButton()
                .padding(.horizontal, 32)
            }
        }
    }
}
