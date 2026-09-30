import SwiftUI

/// The first-run display name is local and can be changed later in Settings.
struct DisplayNameView: View {
    var onContinue: () -> Void

    @AppStorage(OnboardingKeys.displayName) private var storedName = ""
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Text("What should we call you?")
                        .themeDisplayText()
                        .multilineTextAlignment(.center)
                    Text("This is the name WaifuClaw uses when it talks to you. Anything you like — you can change it later in Settings.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)

                TextField("Your name", text: $name)
                    .font(Theme.title)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(16)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.hairline, lineWidth: 1)
                    }
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(continueTapped)
                    .accessibilityLabel("Your display name")
                    .accessibilityHint("Type the name WaifuClaw should call you")

                Button("Continue", action: continueTapped)
                    .themePrimaryButton()
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("onboarding.finish")
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if name.isEmpty { name = storedName }
            // Do not open the keyboard automatically: on small devices it can
            // cover the action and trigger a system keyboard-coaching overlay.
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func continueTapped() {
        let clean = trimmedName
        guard !clean.isEmpty else { return }
        nameFocused = false
        storedName = clean
        onContinue()
    }
}
