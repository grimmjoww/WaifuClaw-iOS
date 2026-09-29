import SwiftUI

/// One permission in the first-launch flow: explainer first, then the real
/// iOS system prompt, then an honest result.
///
/// - Explainer: what it's for and the Allow / Not now choice (the button).
/// - Requesting: visible progress while iOS is asking.
/// - Result: loud and honest. Granted → confirmed. Denied → exactly what
///   won't work, plus a way to fix it in the Settings app, plus Continue.
///   Unavailable → why, plus Continue. The flow always continues respectfully.
struct PermissionStepView: View {
    var kind: PermissionKind
    var onContinue: () -> Void

    private enum Phase {
        case explainer
        case requesting
        case result
    }

    @AppStorage(OnboardingKeys.notificationsGranted) private var notificationsGranted = false
    @AppStorage(OnboardingKeys.faceIDEnabled) private var faceIDEnabled = false
    @AppStorage(OnboardingKeys.localNetworkRequested) private var localNetworkRequested = false

    @State private var phase: Phase = .explainer
    @State private var result: PermissionResult?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            switch phase {
            case .explainer:
                explainerContent
            case .requesting:
                requestingContent
            case .result:
                resultContent
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut, value: phase)
    }

    // MARK: - Explainer

    private var explainerContent: some View {
        VStack(spacing: 16) {
            permissionIcon
            Text(kind.title)
                .themeDisplayText()
                .multilineTextAlignment(.center)
            Text(kind.explainer)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            VStack(spacing: 12) {
                Button("Allow", action: allowTapped)
                    .themePrimaryButton()
                Button("Not now", action: skipTapped)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)
            }
            .padding(.top, 8)
        }
        .accessibilityElement(children: .contain)
    }

    private var permissionIcon: some View {
        ZStack {
            Circle()
                .fill(Theme.magentaGradient)
                .frame(width: 96, height: 96)
                .shadow(color: Theme.magenta.opacity(0.35), radius: 20)
            Image(systemName: kind.systemIcon)
                .font(.system(size: 40))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Requesting

    private var requestingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Theme.magenta)
                .scaleEffect(1.4)
            Text(kind == .localNetwork ? "iOS is asking…" : "Waiting for iOS…")
                .font(Theme.headline)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Requesting \(kind.title) permission")
    }

    // MARK: - Result

    @ViewBuilder
    private var resultContent: some View {
        switch result {
        case .granted:
            resultCard(
                icon: "checkmark.circle.fill",
                tint: Theme.success,
                heading: "You're all set",
                body: grantedBody
            )
        case .denied:
            resultCard(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.warning,
                heading: kind.deniedHeading,
                body: kind.deniedBody,
                showSettingsButton: true
            )
        case .unavailable(let reason):
            resultCard(
                icon: "info.circle.fill",
                tint: Theme.textSecondary,
                heading: "Not available",
                body: "\(kind.unavailableBody) (\(reason))"
            )
        case .unknown:
            resultCard(
                icon: "checkmark.circle.fill",
                tint: Theme.success,
                heading: "Asked",
                body: "iOS showed its prompt — the final call lives in the Settings app. "
                    + "If you tapped Don't Allow, you can change it there later."
            )
        case .none:
            EmptyView()
        }
    }

    private var grantedBody: String {
        switch kind {
        case .notifications:
            "We'll tap you when runs finish and reviews need your eyes."
        case .faceID:
            "WaifuClaw locks itself behind Face ID from now on."
        case .localNetwork:
            // Unreachable: the local-network path reports `.unknown`, never
            // `.granted`, because iOS won't disclose the grant.
            "iOS has the final say on local-network access."
        }
    }

    private func resultCard(
        icon: String,
        tint: Color,
        heading: String,
        body: String,
        showSettingsButton: Bool = false
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(heading)
                .font(Theme.title)
                .bold()
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(body)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            VStack(spacing: 12) {
                if showSettingsButton {
                    Button("Open Settings", action: openSettingsTapped)
                        .themePrimaryButton()
                }
                Button(
                    showSettingsButton ? "Continue anyway" : "Continue",
                    action: onContinue
                )
                .font(Theme.headline)
                .foregroundStyle(showSettingsButton ? Theme.textSecondary : Theme.magenta)
                .frame(minHeight: 44)
            }
            .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(heading). \(body)")
    }

    // MARK: - Actions (logic out of the body)

    private func allowTapped() {
        phase = .requesting
        Task {
            do {
                let outcome = try await kind.request()
                apply(outcome)
            } catch is CancellationError {
                // User left mid-step: back to the explainer, no invented state.
                phase = .explainer
            } catch {
                result = .unavailable(reason: error.localizedDescription)
                phase = .result
            }
        }
    }

    private func skipTapped() {
        record(.denied)
        onContinue()
    }

    private func apply(_ outcome: PermissionResult) {
        record(outcome)
        result = outcome
        phase = .result
    }

    /// Records what happened so Settings can reflect it later.
    /// Never records a grant that didn't happen.
    private func record(_ outcome: PermissionResult) {
        switch kind {
        case .notifications:
            notificationsGranted = (outcome == .granted)
        case .faceID:
            faceIDEnabled = (outcome == .granted)
        case .localNetwork:
            // iOS won't tell us the grant; record that the prompt was shown.
            localNetworkRequested = (outcome != .denied)
        }
    }

    private func openSettingsTapped() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
