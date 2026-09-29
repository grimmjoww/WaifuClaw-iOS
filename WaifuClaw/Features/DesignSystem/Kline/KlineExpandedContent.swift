import SwiftUI

/// The expanded body of `KlinePanel`: her current action, a rotating
/// operator quote, and a system hint. The quote advances on a timer that
/// `task()` cancels automatically when the view disappears. Under Reduce
/// Motion the quote still rotates, but without the crossfade.
struct KlineExpandedContent: View {
    var currentAction: String
    var hint: String

    @State private var quoteIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Current action") {
                Text(currentAction)
                    .foregroundStyle(Theme.textPrimary)
            }
            .font(.callout)

            Divider()
                .overlay(Theme.magenta.opacity(0.25))

            Text("\u{201C}\(KlineQuotes.all[quoteIndex])\u{201D}")
                .font(.callout)
                .italic()
                .foregroundStyle(Theme.textSecondary)
                .id(quoteIndex)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: quoteIndex)
                .accessibilityLabel("Kline says: \(KlineQuotes.all[quoteIndex])")

            Label(hint, systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .task {
            await rotateQuotes()
        }
    }

    private func rotateQuotes() async {
        guard KlineQuotes.all.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(14))
            quoteIndex = (quoteIndex + 1) % KlineQuotes.all.count
        }
    }
}

#Preview {
    KlineExpandedContent(
        currentAction: "Verifying evidence on OR-2026-09-29-01.",
        hint: "Rollback is always one tap away."
    )
    .padding()
    .background(Theme.surface)
}
