import SwiftUI

// MARK: - Runs list (leaf 1.3.2)
//
// The Runs tab: the phone translation of mockup 2's OutcomeRun header —
// run identity (ID, objective, progress, status, current step) as cards.
// Contract §4 (REDESIGN-CONTRACT.md) is the layout authority.
//
// Data: consumes the `RunsData` protocol only (leaf 1.3.1) — never
// APIClient. Previews use `MockRunsData`; the App-integration leaf (1.6.1)
// injects the live provider and wraps this view in its NavigationStack.
//
// HARD CONTRACT (leaf 1.3.1 backend verification): no canary/promotion
// endpoint and no run-context agent-messaging endpoint exist — those
// buttons/rows are DEAD and appear nowhere on this screen. Rollback
// (POST cancel?action=rollback) is surfaced on the DETAIL screen only
// (leaf 1.3.3), never here.
//
// Willie's three questions:
//   1. Buttons/settings: filter chips filter (real), cards navigate to the
//      detail screen (real), Retry retries the load (real). No decorative
//      controls — the filter row hides when there is nothing to filter.
//   2. Visible feedback: skeletons → content; pull-to-refresh spins until
//      the load settles; Retry returns to skeletons, then content or error.
//   3. Loud failure: full error card + Retry on first-load failure; a
//      warning banner (stale list kept) when a refresh fails.

// MARK: - Filter

/// Runs-list filter (contract §4 GAP-01 chips: All / Running / Frozen /
/// Failed). "Frozen" is the UI name for backend `interrupted` (see
/// RunStatus.badgeText); "Failed" covers error + timeout.
enum RunsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case frozen = "Frozen"
    case failed = "Failed"

    var id: String { rawValue }

    func matches(_ status: RunStatus) -> Bool {
        switch self {
        case .all:
            true
        case .running:
            status == .running
        case .frozen:
            status == .interrupted
        case .failed:
            status == .error || status == .timeout
        }
    }
}

// MARK: - View model

/// Owns Runs-list load state. Depends on `RunsData` only — never on
/// APIClient — so previews and the App-integration leaf can swap
/// mock/live sources freely.
@Observable
@MainActor
final class RunsListViewModel {
    /// What the list is showing right now.
    enum Phase: Equatable {
        case loading
        case ready
        case error(RunsError)
    }

    private(set) var phase: Phase = .loading
    private(set) var runs: [RunSummary] = []
    /// Set when a refresh fails but older data is still on screen — the
    /// stale list stays usable and the failure is loud (banner), never
    /// silent and never a blank screen.
    private(set) var refreshNotice: String?

    /// Stored as a Sendable existential so the nonisolated init below is
    /// provably safe: both conformances are Sendable structs (MockRunsData
    /// holds a plain enum; LiveRunsData holds only the @MainActor-isolated
    /// APIClient, and global-actor-isolated types are Sendable).
    private let data: any RunsData & Sendable
    /// Monotonic generation: a cancelled or superseded load can never
    /// overwrite newer state, even if cancellation lands between its
    /// last await and its assignment.
    private var generation = 0

    /// Nonisolated so SwiftUI views can construct the model in their own
    /// (nonisolated) initializers; the init only stores the data source.
    /// (Same fix as the BYOK leaf's Swift 6 init-isolation diagnostic.)
    nonisolated init(data: any RunsData & Sendable) {
        self.data = data
    }

    /// (Re)loads the list. Safe to call from .task, .refreshable, and
    /// Retry — a superseded load never wins (generation counter).
    func refresh() async {
        generation += 1
        let current = generation
        if runs.isEmpty {
            phase = .loading
        }
        refreshNotice = nil
        do {
            let fetched = try await data.recentRuns(limit: 50)
            guard isCurrent(current) else { return }
            runs = fetched
            phase = .ready
        } catch is CancellationError {
            // Normal lifecycle (view gone, refresh superseded) — never
            // mapped to a UI error (bug-patterns.md).
            return
        } catch {
            guard isCurrent(current) else { return }
            // Preserve the specific RunsError the mock throws; map anything
            // else through the loud-failure mapper.
            let runsError = (error as? RunsError) ?? RunsError.describe(error)
            if runs.isEmpty {
                phase = .error(runsError)
            } else {
                refreshNotice = runsError.localizedDescription
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }
}

// MARK: - Runs list view

/// The Runs tab root. Expects to live inside a NavigationStack (provided
/// by the App-integration leaf, mirroring MainTabView's other tabs).
struct RunsListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: RunsListViewModel
    @State private var filter: RunsFilter = .all

    /// - Parameter data: the runs source. `MockRunsData(mode:)` in
    ///   previews; the live provider in the real app (leaf 1.6.1).
    init(data: any RunsData & Sendable) {
        _viewModel = State(initialValue: RunsListViewModel(data: data))
    }

    private var filteredRuns: [RunSummary] {
        viewModel.runs.filter { filter.matches($0.status) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleView
                    switch viewModel.phase {
                    case .loading:
                        skeletonList
                    case .error(let runsError):
                        RunsErrorCard(error: runsError) {
                            Task { await viewModel.refresh() }
                        }
                    case .ready:
                        readyContent
                    }
                }
                .padding(.vertical, 8)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        // Contract §4: the dimensional title replaces the nav-bar title
        // (inline, never large-title).
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Title

    /// Dimensional display title. Uses themeDisplayText() until GAP-06
    /// DimensionalTitle exists as a shared component.
    private var titleView: some View {
        Text("Runs")
            .themeDisplayText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Ready state

    @ViewBuilder
    private var readyContent: some View {
        if let notice = viewModel.refreshNotice {
            refreshNoticeBanner(notice)
        }
        if viewModel.runs.isEmpty {
            RunsEmptyState(
                title: "No runs yet.",
                message: "Runs appear here when your desktop starts one."
            )
        } else {
            filterChips
            if filteredRuns.isEmpty {
                RunsEmptyState(
                    title: "No runs match this filter.",
                    message: "Try a different filter — nothing is hidden, just filtered out."
                )
            } else {
                runCards
            }
        }
    }

    /// GAP-08-style banner: warning tint, never silent about a failed refresh.
    private func refreshNoticeBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.15))
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filter chips (GAP-01, in-file until the shared component exists)

    /// Horizontal chip row. Hidden when there is nothing to filter — a
    /// filter row over an empty list would be a decorative control.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RunsFilter.allCases) { option in
                    RunsFilterChip(
                        title: option.rawValue,
                        selected: filter == option
                    ) {
                        filter = option
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Run cards

    private var runCards: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredRuns) { run in
                // Leaf 1.3.3 owns RunDetailView — it takes the run as a
                // param. This reference compiles once 1.3.3 lands.
                NavigationLink {
                    RunDetailView(run: run)
                } label: {
                    RunRow(run: run)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: filter)
    }

    // MARK: - Loading skeletons (GAP-05 stand-in: static blocks)

    private var skeletonList: some View {
        LazyVStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RunsSkeletonRow()
            }
        }
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Run row (contract §4 card)

/// One run card: mono run ID + status badge, objective (2-line max),
/// progress bar + "% · Step N of M", risk/timing metadata. 44pt+ tap
/// target via the enclosing NavigationLink.
private struct RunRow: View {
    let run: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(run.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                StatusBadge(text: run.status.badgeText, tone: badgeTone(for: run.status))
            }
            Text(run.displayObjective)
                .font(.headline)
                .bold()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            progressSection
            if let metadata = metadataText {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var progressSection: some View {
        if let progress = run.progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: progress)
                Text("\(Int(progress * 100))%\(run.stepText.map { " · \($0)" } ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if let stepText = run.stepText {
            // Indeterminate progress: show the step honestly, never a 0% bar.
            Text(stepText)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Risk tier (mock-only today; nil from live) + relative timing.
    private var metadataText: String? {
        var parts: [String] = []
        if let tier = run.riskTier {
            parts.append(tier.badgeText)
        }
        if let date = run.updatedAt ?? run.startedAt {
            parts.append(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = ["Run \(run.id)", run.displayObjective, run.status.badgeText]
        if let progress = run.progress {
            parts.append("\(Int(progress * 100)) percent")
        }
        if let stepText = run.stepText {
            parts.append(stepText)
        }
        return parts.joined(separator: ", ")
    }

    private func badgeTone(for status: RunStatus) -> BadgeTone {
        // Contract §4: Running .success / Frozen .info / Failed .danger /
        // Pending .neutral. Timeout is a failure, hence .danger.
        switch status {
        case .pending: .neutral
        case .running: .success
        case .success: .success
        case .error: .danger
        case .timeout: .danger
        case .interrupted: .info
        case .unknown: .neutral
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Filter chip (GAP-01 spec, in-file)

/// Selectable capsule per GAP-01: 44pt min height, selected = magenta bg +
/// white bold text, unselected = surface bg + secondary text + hairline
/// border. A real Button, never onTapGesture (contract §13).
private struct RunsFilterChip: View {
    let title: String
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(title)
                .font(.subheadline)
                .bold(selected)
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(selected ? Theme.magenta : Theme.surface)
                .overlay {
                    if !selected {
                        Capsule()
                            .stroke(Theme.textSecondary.opacity(0.3), lineWidth: 1)
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) filter")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Error card (GAP-07 spec, in-file)

/// Loud failure card: danger rail, what failed, and a real Retry button.
/// Announced as a unit to VoiceOver.
private struct RunsErrorCard: View {
    let error: RunsError
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Theme.danger.frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Couldn't load runs.")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                }
                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                Button("Retry", action: onRetry)
                    .themePrimaryButton()
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state (GAP-04 spec, in-file)

/// Bespoke art + title + honest explanation. No CTA button: there is no
/// "start run" endpoint, so a button would be an orphan capability
/// (contract §12.9). The SF tray icon is a stand-in until the bespoke
/// `empty-no-runs` art (§11) exists.
private struct RunsEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                .padding(.top, 32)
            Text(title)
                .font(.title3)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Skeleton row (GAP-05 stand-in: static blocks)

/// Loading placeholder matching the card shape. Static blocks (no shimmer)
/// until the shared SkeletonCard exists — static is also what Reduce
/// Motion requires.
private struct RunsSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.track)
                    .frame(width: 120, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 11)
                    .fill(Theme.track)
                    .frame(width: 84, height: 22)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.track)
                .frame(height: 20)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.track)
                .frame(height: 8)
        }
        .themeCard()
    }
}

// MARK: - Previews (all loud-failure states, via the real view model)

#Preview("Runs — loaded") {
    NavigationStack {
        RunsListView(data: MockRunsData(mode: .loaded))
    }
    .preferredColorScheme(.dark)
}

#Preview("Runs — empty") {
    NavigationStack {
        RunsListView(data: MockRunsData(mode: .empty))
    }
    .preferredColorScheme(.dark)
}

#Preview("Runs — error") {
    NavigationStack {
        RunsListView(data: MockRunsData(mode: .error))
    }
    .preferredColorScheme(.dark)
}

#Preview("Runs — offline") {
    NavigationStack {
        RunsListView(data: MockRunsData(mode: .offline))
    }
    .preferredColorScheme(.dark)
}

#Preview("Runs — unpaired") {
    NavigationStack {
        RunsListView(data: MockRunsData(mode: .unpaired))
    }
    .preferredColorScheme(.dark)
}
