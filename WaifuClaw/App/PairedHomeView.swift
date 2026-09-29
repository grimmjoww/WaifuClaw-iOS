import SwiftUI

/// Home tab root: mounts the wave-2 HomeView on live data.
///
/// The VM is built in the init *body* (never a default parameter) — the
/// Swift 6 finding from leaf 1.2.2: constructing a @MainActor @Observable VM
/// in a default parameter of a nonisolated view init fails CI.
struct PairedHomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewModel: HomeViewModel
    private let healthData: LiveSystemHealthData

    init(api: APIClient, computer: PairedComputer, userName: String) {
        _viewModel = State(initialValue: HomeViewModel(data: LiveDashboardData(api: api, userName: userName)))
        self.healthData = LiveSystemHealthData(api: api, pairedComputer: computer)
    }

    var body: some View {
        HomeView(
            viewModel: viewModel,
            systemHealthData: healthData,
            onViewAllThreads: { appState.tabSelection = .runs },
            onPairPhone: nil // already paired — nil hides the button (no dead controls)
        )
        .navigationTitle("Home")
    }
}
