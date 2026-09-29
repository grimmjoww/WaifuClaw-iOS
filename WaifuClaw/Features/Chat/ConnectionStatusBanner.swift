import SwiftUI

/// Persistent connection health indicator pinned above the tab content
/// (audit §6). Green = quiet; anything else says what's wrong and offers
/// Retry. Never a dead silent offline state.
struct ConnectionStatusBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.connection {
        case .connected:
            EmptyView()
        case .checking, .unknown:
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .tint(Theme.textSecondary)
                    .scaleEffect(0.7)
                Text("Checking connection…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Theme.surface)
        case .notConnected(let message):
            Button {
                Task { await appState.refreshConnection() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Text("Retry")
                        .font(.caption)
                        .bold()
                }
                .foregroundStyle(Theme.warning)
                .padding(.vertical, 8)
                .padding(.horizontal)
                .frame(maxWidth: .infinity)
                .background(Theme.warning.opacity(0.12))
            }
        }
    }
}
