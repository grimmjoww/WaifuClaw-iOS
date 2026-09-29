import SwiftUI

/// Defensive fallback: AppState sets `api` before flipping `pairing` to
/// `.paired`, so a paired tab with no client should be unreachable. If the
/// invariant ever breaks, this says so loudly with a way back — never a
/// blank tab, never a force-unwrap (Willie's question 3).
struct ApiTransientView: View {
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Theme.warning)
            Text("Connection wasn't ready")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("The phone is paired but the connection client wasn't built. Retrying rebuilds it from your saved pairing.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .themePrimaryButton()
        }
        .padding(32)
    }
}
