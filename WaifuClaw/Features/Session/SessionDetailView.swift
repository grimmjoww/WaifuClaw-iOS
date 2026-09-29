import SwiftUI

// MARK: - Session detail

/// Read-only window into one agent session: run header, live terminal,
/// skill activity, the Kline line, and the honest footer. No editing
/// happens here — the phone is a window, not a workbench.
struct SessionDetailView: View {
    @State private var viewModel: SessionDetailViewModel
    private let summary: RunSummary

    /// - Parameters:
    ///   - summary: the run this session shows (from the session list or
    ///     the run detail's "View session" link).
    ///   - data: the session source. `MockSessionData()` in previews; the
    ///     live provider in the real app (leaf 1.6.1).
    init(summary: RunSummary, data: any SessionData & Sendable) {
        self.summary = summary
        _viewModel = State(initialValue: SessionDetailViewModel(summary: summary, data: data))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingL) {
                    headerCard
                    SessionTerminalCard(viewModel: viewModel)
                    SessionSkillsCard(viewModel: viewModel)
                    klineRow
                    footer
                }
                .padding(Theme.spacingL)
            }
        }
        .navigationTitle(summary.id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.start()
        }
        .onDisappear {
            // The stored stream task must not outlive this view.
            viewModel.stop()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text(summary.displayObjective)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.spacingS) {
                StatusBadge(
                    text: summary.status.badgeText,
                    tone: SessionListView.tone(for: summary.status)
                )
                if let stepText = summary.stepText {
                    Text(stepText)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let started = summary.startedAt {
                    Text(Self.dateFormatter.string(from: started))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Run \(summary.id)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.displayObjective). Status: \(summary.status.badgeText).")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Kline micro-row

    /// Contract §8 item 4: the Kline line, always present.
    private var klineRow: some View {
        HStack(spacing: Theme.spacingM) {
            Circle()
                .fill(Theme.magentaGradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Text("K")
                        .font(Theme.headline)
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kline")
                    .font(Theme.caption)
                    .bold()
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                Text("I learn first, then I build.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kline says: I learn first, then I build.")
    }

    // MARK: - Footer

    /// Contract §8 item 5: the honest footer.
    private var footer: some View {
        Text("Editing happens on your desktop — this is a window, not a workbench.")
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.spacingS)
            .accessibilityLabel("Editing happens on your desktop. This is a window, not a workbench.")
    }
}

#Preview("Detail — loaded") {
    NavigationStack {
        SessionDetailView(summary: MockRunsData.summaries[0], data: MockSessionData())
    }
    .preferredColorScheme(.dark)
}

#Preview("Detail — empty") {
    NavigationStack {
        SessionDetailView(summary: MockRunsData.summaries[1], data: MockSessionData(mode: .empty))
    }
    .preferredColorScheme(.dark)
}
