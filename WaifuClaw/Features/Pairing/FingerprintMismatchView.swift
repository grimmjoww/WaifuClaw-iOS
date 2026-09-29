import SwiftUI

/// Blocking full-screen TOFU fingerprint mismatch warning (audit §4).
/// Never auto-trusts, never fails silently. The safe choice (Cancel) is the
/// prominent one; trusting the new certificate is an explicit, scary action.
struct FingerprintMismatchView: View {
    @EnvironmentObject var appState: AppState
    let alert: FingerprintAlert

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 48)

                    Text("Security warning")
                        .font(.title.bold())
                        .foregroundStyle(Theme.textPrimary)

                    Text("Your computer's identity changed.")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Text("The security fingerprint your phone remembered doesn't match the computer it's talking to now. This can happen if WaifuClaw was reinstalled or generated a new certificate — or someone could be intercepting your connection.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        FingerprintRow(label: "Remembered", value: short(alert.expected))
                        FingerprintRow(label: "Seen now", value: short(alert.actual))
                    }
                    .themeCard()
                    .padding(.horizontal)

                    // Safe default, prominent.
                    Button("Cancel") {
                        appState.dismissSecurityAlert()
                    }
                    .themePrimaryButton()
                    .padding(.horizontal, 32)

                    // Explicit scary action, visually secondary.
                    Button("Trust new certificate") {
                        appState.trustNewFingerprint()
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func short(_ fingerprint: String) -> String {
        guard fingerprint.count > 16 else { return fingerprint }
        return "\(fingerprint.prefix(8))…\(fingerprint.suffix(8))"
    }
}

private struct FingerprintRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
