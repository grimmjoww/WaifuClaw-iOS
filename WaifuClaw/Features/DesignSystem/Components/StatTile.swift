import SwiftUI

/// Icon + headline value + caption label, on a theme card.
/// Matches the mockups' stat boxes (e.g. "12/12 Active", "87% Memory Recall").
struct StatTile: View {
    /// SF Symbol shown next to the label; decorative (the label carries meaning).
    var systemImage: String
    /// The headline number or short string.
    var value: String
    /// Caption describing the value.
    var label: String
    /// Optional smaller line under the value (e.g. "Last recall: 2m ago").
    var sublabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.magenta)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.title2)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            if let sublabel {
                Text(sublabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview {
    HStack(spacing: 12) {
        StatTile(systemImage: "wrench.and.screwdriver", value: "12/12", label: "Tools Active")
        StatTile(systemImage: "brain", value: "87%", label: "Memory Recall", sublabel: "Last recall: 2m ago")
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
