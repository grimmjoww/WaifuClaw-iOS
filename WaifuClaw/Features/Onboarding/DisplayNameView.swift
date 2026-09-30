import SwiftUI

/// Display-name entry: "What should we call you?"
///
/// Free text — any name the person types. Persisted to
/// `OnboardingKeys.displayName`; other screens read that key for greetings.
/// No user name is ever hard-coded anywhere in this flow.
struct DisplayNameView: View {
    var onContinue: () -> Void

    @AppStorage(OnboardingKeys.displayName) private var storedName = ""
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Text("What should we call you?")
                    .themeDisplayText()
                    .multilineTextAlignment(.center)
                Text("This is the name WaifuClaw uses when it talks to you. Anything you like — you can change it later in Settings.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
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
                .padding(.horizontal, 16)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(continueTapped)
                .accessibilityLabel("Your display name")
                .accessibilityHint("Type the name WaifuClaw should call you")
            Button("Continue", action: continueTapped)
                .themePrimaryButton()
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("onboarding.finish")
                .padding(.horizontal, 16)
            Spacer()
        }
        .onAppear {
            // Replaying setup keeps whatever was entered before.
            if name.isEmpty { name = storedName }
            nameFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func continueTapped() {
        let clean = trimmedName
        guard !clean.isEmpty else { return }
        storedName = clean
        onContinue()
    }
}
