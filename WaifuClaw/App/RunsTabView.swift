import SwiftUI

/// Runs tab: the wave-2 Runs list and the live session surface behind a
/// segmented switch. A session is the live face of a run, so they share the
/// tab instead of taking two tab-bar slots.
struct RunsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var segment: Segment = .runs

    private enum Segment {
        case runs
        case sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Runs view", selection: $segment) {
                Text("Runs").tag(Segment.runs)
                Text("Sessions").tag(Segment.sessions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            if let api = appState.api {
                switch segment {
                case .runs:
                    RunsListView(data: LiveRunsData(api: api))
                case .sessions:
                    SessionListView(
                        runsData: LiveRunsData(api: api),
                        sessionData: LiveSessionData(api: api)
                    )
                }
            } else {
                ApiTransientView(onRetry: retryConnection)
            }
        }
        .navigationTitle(segment == .runs ? "Runs" : "Live Sessions")
    }

    private func retryConnection() {
        Task { await appState.restore() }
    }
}
