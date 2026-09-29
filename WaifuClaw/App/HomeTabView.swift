import SwiftUI

/// Home tab: routes paired → live dashboard, and guards the (defensive-only)
/// paired-without-client case loudly instead of crashing.
///
/// The display name is read here and passed down so a rename in Settings
/// rebuilds the dashboard (via .id) instead of showing a stale greeting.
struct HomeTabView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(OnboardingKeys.displayName) private var displayName = ""

    var body: some View {
        if case .paired(let computer) = appState.pairing, let api = appState.api {
            PairedHomeView(api: api, computer: computer, userName: displayName)
                .id(displayName)
        } else {
            ApiTransientView(onRetry: retryConnection)
        }
    }

    private func retryConnection() {
        Task { await appState.restore() }
    }
}
