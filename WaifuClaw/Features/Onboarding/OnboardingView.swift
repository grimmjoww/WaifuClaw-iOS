import SwiftUI

/// First launch explains the phone-local agent and asks for a display name.
/// Notification and biometric prompts are intentionally absent until the
/// app has real notification delivery and an enforced app-lock feature.
struct OnboardingView: View {
    var onComplete: () -> Void

    @AppStorage(OnboardingKeys.hasCompletedOnboarding) private var hasCompleted = false
    @State private var step: OnboardingStep = .intro

    init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                progressHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                stepContent
            }
        }
        .animation(.easeInOut, value: step)
    }

    // MARK: - Progress (visible feedback: where you are in the flow)

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Step \(step.position) of \(OnboardingStep.allCases.count)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(step.title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ProgressBar(
                value: Double(step.position) / Double(OnboardingStep.allCases.count),
                height: 6
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue("Step \(step.position) of \(OnboardingStep.allCases.count): \(step.title)")
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .intro:
            IntroPagesView(onContinue: advance)
        case .displayName:
            DisplayNameView(onContinue: advance)
        }
    }

    private func advance() {
        if let next = step.next {
            step = next
        } else {
            hasCompleted = true
            onComplete()
        }
    }
}
