import Foundation
import SwiftUI

/// Resolves resources from the installed WaifuClaw application bundle even
/// while XCTest runs in a separate test bundle. Kept deliberately small so
/// resource validation never depends on `Bundle.main` host behavior.
final class WaifuClawAppBundleMarker: NSObject {
    static var bundle: Bundle { Bundle(for: WaifuClawAppBundleMarker.self) }
}

@main
struct WaifuClawApp: App {
    init() {
        StudioFontRegistration.registerIfNeeded()
        #if DEBUG
        // A command-line UserDefaults override of false cannot be changed by
        // onboarding. Reset the persisted value once instead in UI test builds.
        if ProcessInfo.processInfo.environment["WAIFUCLAW_UI_TEST_RESET_ONBOARDING"] == "1" {
            UserDefaults.standard.removeObject(forKey: OnboardingKeys.hasCompletedOnboarding)
        }
        #endif
    }

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
                OnboardingView(onComplete: { hasCompletedOnboarding = true })
            }
        }
        .tint(Theme.magenta)
    }
}

private enum NativeTab: Hashable {
    case home
    case agent
    case workspace
    case memory
    case settings
}

/// Mount only real phone-local data and controls. Team is reachable from Home;
/// full OutcomeRun governance and a purchasable Pro tier remain release gates.
struct MainTabView: View {
    @State private var selectedTab: NativeTab = .home
    @State private var requestedConversationID: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NativeHomeView(
                    openAgent: { selectedTab = .agent },
                    openWorkspace: { selectedTab = .workspace },
                    openSettings: { selectedTab = .settings },
                    openConversation: { id in
                        requestedConversationID = id
                        selectedTab = .agent
                    }
                )
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(NativeTab.home)

            NavigationStack {
                NativeAgentView(requestedConversationID: requestedConversationID)
            }
            .tabItem { Label("Agent", systemImage: "bubble.left.and.text.bubble.right.fill") }
            .tag(NativeTab.agent)

            NavigationStack {
                NativeWorkspaceView()
            }
            .tabItem { Label("Workspace", systemImage: "curlybraces.square.fill") }
            .tag(NativeTab.workspace)

            NavigationStack {
                NativeMemoryView()
            }
            .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            .tag(NativeTab.memory)

            NavigationStack {
                NativeSettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(NativeTab.settings)
        }
    }
}
