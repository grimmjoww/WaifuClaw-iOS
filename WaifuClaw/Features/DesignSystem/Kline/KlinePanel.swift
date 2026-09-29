import SwiftUI

/// KLINE — the "Operator & Guide" panel.
///
/// Phone adaptation of the right-hand Kline rail from the desktop mockups:
/// a collapsible card instead of a side rail. Collapsed it shows her avatar,
/// name, and one-line status; expanded it shows her current action, a
/// rotating operator quote, and a system hint.
///
/// LOUD ART NOTE (no silent fake): the portrait loads `kline-operator.png`
/// from this folder, which ships inside the app bundle via the `ios/project.yml`
/// source glob (XcodeGen adds non-compilable files under `WaifuClaw/` to the
/// app target's resources). If that packaging ever breaks, `KlineAvatar`
/// degrades to a magenta monogram circle — a deliberate, documented
/// fallback, never a silent blank.
struct KlinePanel: View {
    var status: String
    var currentAction: String
    var hint: String

    @State private var isExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        status: String = "Monitoring all systems",
        currentAction: String = "Standing by for your next run.",
        hint: String = "No approval binds to changed bytes."
    ) {
        self.status = status
        self.currentAction = currentAction
        self.hint = hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                KlinePanelHeader(status: status, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded ? "Kline, Operator and Guide. Expanded. Activate to collapse."
                    : "Kline, Operator and Guide. Collapsed. Activate to expand."
            )
            .accessibilityHint("Shows Kline's current action and operator notes.")

            if isExpanded {
                KlineExpandedContent(currentAction: currentAction, hint: hint)
                    .padding(.top, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .themeCard()
        .overlay(alignment: .top) {
            // Magenta hairline: the Phantom Horizons accent from the mockup rail.
            Theme.magenta
                .frame(height: 2)
                .clipShape(.rect(cornerRadius: 1))
                .padding(.horizontal, 16)
                .opacity(0.8)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.25), value: isExpanded)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}

#Preview {
    VStack(spacing: 16) {
        KlinePanel()
        KlinePanel(
            status: "Reviewing frozen candidate",
            currentAction: "Verifying evidence on OR-2026-09-29-01.",
            hint: "Rollback is always one tap away."
        )
    }
    .padding()
    .background(Theme.background)
}
