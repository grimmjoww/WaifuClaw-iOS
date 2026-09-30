import SwiftUI

@main
struct WaifuClawApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Existing desktop credentials remain stored for an explicit migration path,
/// but they are not needed to open or operate the native iPhone agent.
struct RootView: View {
    @AppStorage(OnboardingKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .tint(Theme.magenta)
    }
}

private enum NativeTab: Hashable {
    case home
    case agent
    case settings
}

/// Mount a feature only when its real phone-local data and controls exist.
/// Runs, Team, Memory, Plugins and Pro join this shell as their native stores
/// and working actions are delivered, not as preview fixtures.
struct MainTabView: View {
    @State private var selectedTab: NativeTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NativeHomeView(
                    openAgent: { selectedTab = .agent },
                    openSettings: { selectedTab = .settings }
                )
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(NativeTab.home)

            NavigationStack {
                NativeAgentView()
            }
            .tabItem { Label("Agent", systemImage: "bubble.left.and.text.bubble.right.fill") }
            .tag(NativeTab.agent)

            NavigationStack {
                NativeSettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(NativeTab.settings)
        }
    }
}
