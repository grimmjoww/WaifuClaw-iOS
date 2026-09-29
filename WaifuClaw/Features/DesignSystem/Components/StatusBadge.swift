import SwiftUI

/// Small colored pill for statuses ("FROZEN", "In Progress", "Medium", ...).
/// Tone comes from BadgeTone so the badge is never color-only.
struct StatusBadge: View {
    /// Text shown inside the pill.
    var text: String
    /// Visual tone; defaults to info (magenta).
    var tone: BadgeTone = .info

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
                .bold()
        } icon: {
            Image(systemName: tone.symbolName)
                .font(.caption)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.14))
        .clipShape(Capsule())
        .accessibilityLabel("\(text)")
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBadge(text: "FROZEN", tone: .info)
        StatusBadge(text: "In Progress", tone: .success)
        StatusBadge(text: "Medium", tone: .warning)
        StatusBadge(text: "Failed", tone: .danger)
        StatusBadge(text: "Pending", tone: .neutral)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
