import SwiftUI

/// The tappable header row of `KlinePanel`: avatar, name/title, status line,
/// and an expand/collapse chevron. The whole row is the button label; the
/// chevron is decorative because the parent button carries the accessible
/// label. The row is taller than Apple's 44pt minimum tap area.
struct KlinePanelHeader: View {
    var status: String
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            KlineAvatar(diameter: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("KLINE")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Operator & Guide")
                    .font(.subheadline)
                    .foregroundStyle(Theme.magentaSoft)
                Label {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.success)
                        .accessibilityHidden(true)
                }
                // Dot + text (not color alone) so status never depends on
                // color — respects Differentiate Without Color.
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(.callout)
                .bold()
                .foregroundStyle(Theme.magenta)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 56)
    }
}

#Preview {
    KlinePanelHeader(status: "Monitoring all systems", isExpanded: true)
        .padding()
        .background(Theme.surface)
}
