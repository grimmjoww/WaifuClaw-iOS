import SwiftUI

/// Section title row with an optional trailing action ("View all ›").
/// The action is a real Button with a text label, so VoiceOver reads it.
struct SectionHeader: View {
    /// Section title.
    var title: String
    /// Trailing action label, e.g. "View all". Nil hides the button.
    var actionTitle: String?
    /// Runs when the trailing action is tapped.
    var onAction: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let actionTitle, let onAction {
                Button(actionTitle, systemImage: "chevron.right", action: onAction)
                    .font(.subheadline)
                    .foregroundStyle(Theme.magenta)
                    // design.md: keep tap targets at least 44x44.
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SectionHeader(title: "Today's OutcomeRun", actionTitle: "View all") {}
        SectionHeader(title: "System Health")
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
