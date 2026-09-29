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

/// Routes to pairing or the main tabs based on pairing state.
struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch appState.pairing {
            case .unpaired:
                PairingFlowView()
            case .paired:
                MainTabView()
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
                ThreadListView()
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(0)

            NavigationStack {
                MemoryBrowserView()
            }
            .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            .tag(1)

            NavigationStack {
                LicenseView()
            }
            .tabItem { Label("Pro", systemImage: "sparkles") }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(3)
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
