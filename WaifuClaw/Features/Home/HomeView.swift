import SwiftUI

// MARK: - Home dashboard (leaf 1.2.2)
//
// Phone translation of the mockup-1 Home dashboard per
// REDESIGN-CONTRACT.md §3. Every section renders its own LoadState from
// HomeViewModel, so sections load and fail independently: skeletons while
// loading, loud error cards with Retry on failure, honest empty states.
// No section ever renders blank.
//
// The display name comes from @AppStorage("displayName"). The onboarding
// leaf owns the write; this screen only reads. Empty/missing → "there".
// The name is never hard-coded.
//
// Contract deviations (per §0, the built foundation wins on conflict):
// - "Current goal" card (§3.4): no goal model exists in DashboardData
//   (leaf 1.2.1, backend-verified) — killed rather than faked.
// - "Today's OutcomeRun" 11-dot timeline (§3.6): ThreadSummary carries no
//   step data — renders as thread rows with status badges instead.
// - "Suggestions" (§3.9): no suggestion model exists — killed. (The contract
//   itself kills decorative suggestions.)
// - "System Health" (§3.7): owned by leaf 1.2.3 (SystemHealthView) —
//   intentionally absent here; 1.6.1 composes it in.
// - GAP-06 DimensionalTitle / GAP-04/05/07 state components don't exist yet —
//   HomeGreeting, HomeSkeleton, HomeEmptyState, HomeErrorCard implement their
//   specs inline (private).
//
// The private section views below live in this file (single-file leaf
// ownership); each is small and used only by HomeView.

struct HomeView: View {
    @AppStorage("displayName") private var displayName = ""
    @State private var viewModel: HomeViewModel

    /// Deep link for "View all" → Runs tab, wired by the App-integration leaf
    /// (1.6.1). Nil hides the action — no dead buttons.
    let onViewAllThreads: (() -> Void)?

    /// - Parameter viewModel: owned via @State (the @Observable pattern).
    ///   Deliberately no mock default: 1.6.1 must inject live/unpaired/mock
    ///   explicitly, so a forgotten injection can never show fake data.
    ///   The @MainActor view-model init is only ever *called* by the
    ///   integrator/previews — never here — so this init stays nonisolated.
    init(viewModel: HomeViewModel, onViewAllThreads: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onViewAllThreads = onViewAllThreads
    }

    private var userName: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "there" : name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingXL) {
                HomeGreeting(userName: userName)
                KlinePanel()
                HomeAgentSection(state: viewModel.agent, onRetry: retryAll)
                HomeStatsSection(
                    agent: viewModel.agent,
                    threads: viewModel.threads,
                    memory: viewModel.memory,
                    onRetry: retryAll
                )
                HomeThreadsSection(
                    state: viewModel.threads,
                    onViewAll: onViewAllThreads,
                    onRetry: retryAll
                )
                HomeMemorySection(state: viewModel.memory, onRetry: retryAll)
            }
            .padding(.horizontal, Theme.spacingL)
            .padding(.vertical, Theme.spacingL)
        }
        .background(Theme.background)
        .task { viewModel.refresh() }
    }

    /// Button actions are @MainActor, so this hop lets section Retry buttons
    /// call the @MainActor view model under Swift 6.
    @MainActor
    private func retryAll() {
        viewModel.refresh()
    }
}

// MARK: - Greeting (GAP-06 spec, inline)

/// The signature greeting: heavy dimensional lettering, tight tracking,
/// magenta gradient on the name, soft magenta shadow. Wraps with Dynamic
/// Type — never truncates.
private struct HomeGreeting: View {
    let userName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            (Text(greeting.salutation + ", ")
                .foregroundStyle(Theme.textPrimary)
                + Text(greeting.userName)
                .foregroundStyle(Theme.displayGradient))
                .font(.system(.largeTitle, design: .default).weight(.heavy))
                .tracking(-0.5)
                .shadow(color: Theme.magenta.opacity(0.35), radius: 8)
                .accessibilityAddTraits(.isHeader)
            Text("Kline and your agents are ready to continue building the future.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var greeting: DashboardGreeting {
        .current(userName: userName)
    }
}

// MARK: - Agent status

private struct HomeAgentSection: View {
    let state: LoadState<ActiveAgentInfo>
    let onRetry: @MainActor () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            HomeSkeleton(height: 92)
        case .failed(let error):
            HomeErrorCard(
                title: "Couldn't load agent status",
                message: error.errorDescription ?? "Something went wrong.",
                onRetry: onRetry
            )
        case .loaded(let info):
            HomeAgentCard(info: info)
        }
    }
}

private struct HomeAgentCard: View {
    let info: ActiveAgentInfo

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            // Bespoke agent medallions (§11) land with the icon pipeline;
            // until then this is an honest generic mark, not a fake portrait.
            ZStack {
                Circle().fill(Theme.background)
                Circle().stroke(Theme.magenta.opacity(0.5), lineWidth: 1.5)
                Image(systemName: "cpu")
                    .foregroundStyle(Theme.magenta)
                    .accessibilityHidden(true)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.isActive ? "Agent online" : "Agent idle")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(info.statusText + (info.currentModel.map { " · \($0)" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            StatusBadge(
                text: info.isActive ? "Online" : "Idle",
                tone: info.isActive ? .success : .neutral
            )
        }
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Agent status: \(info.isActive ? "online" : "idle"). \(info.statusText)."
        )
    }
}

// MARK: - Stats grid ("At a glance")

private struct HomeStatsSection: View {
    let agent: LoadState<ActiveAgentInfo>
    let threads: LoadState<[ThreadSummary]>
    let memory: LoadState<MemorySummary>
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            SectionHeader(title: "At a glance")
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: Theme.spacingM
            ) {
                modelTile
                threadsTile
                memoryTile
            }
        }
    }

    @ViewBuilder
    private var modelTile: some View {
        switch agent {
        case .idle, .loading:
            HomeSkeleton(height: 104)
        case .failed:
            StatErrorTile(onRetry: onRetry)
        case .loaded(let info):
            StatTile(
                systemImage: "cpu",
                value: info.currentModel ?? "Idle",
                label: "Model"
            )
        }
    }

    @ViewBuilder
    private var threadsTile: some View {
        switch threads {
        case .idle, .loading:
            HomeSkeleton(height: 104)
        case .failed:
            StatErrorTile(onRetry: onRetry)
        case .loaded(let list):
            StatTile(
                systemImage: "list.bullet",
                value: "\(list.count)",
                label: "Threads today"
            )
        }
    }

    @ViewBuilder
    private var memoryTile: some View {
        switch memory {
        case .idle, .loading:
            HomeSkeleton(height: 104)
        case .failed:
            StatErrorTile(onRetry: onRetry)
        case .loaded(let summary):
            StatTile(
                systemImage: "brain",
                value: "\(summary.factCount)",
                label: "Memory facts"
            )
        }
    }
}

/// Compact loud-failure tile: a failed stat is never a silent gap.
private struct StatErrorTile: View {
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text("Couldn't load")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel("This stat couldn't load.")
            Button("Retry", action: onRetry)
                .font(.subheadline)
                .foregroundStyle(Theme.magenta)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}

// MARK: - Today's threads

private struct HomeThreadsSection: View {
    let state: LoadState<[ThreadSummary]>
    let onViewAll: (() -> Void)?
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            if case .loaded = state, let onViewAll {
                SectionHeader(
                    title: "Today's threads",
                    actionTitle: "View all",
                    onAction: onViewAll
                )
            } else {
                SectionHeader(title: "Today's threads")
            }
            switch state {
            case .idle, .loading:
                HomeSkeleton(height: 78)
                HomeSkeleton(height: 78)
            case .failed(let error):
                HomeErrorCard(
                    title: "Couldn't load today's threads",
                    message: error.errorDescription ?? "Something went wrong.",
                    onRetry: onRetry
                )
            case .loaded(let list):
                if list.isEmpty {
                    HomeEmptyState(
                        title: "No threads today",
                        message: "Threads appear here when your desktop starts one."
                    )
                } else {
                    ForEach(list) { thread in
                        HomeThreadRow(thread: thread)
                    }
                }
            }
        }
    }
}

private struct HomeThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.displayTitle)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let updated = thread.updatedAt {
                    Text(updated, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            StatusBadge(text: statusText, tone: statusTone)
        }
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.displayTitle), status \(statusText).")
    }

    private var statusText: String {
        switch thread.status {
        case "busy": "Active"
        case "interrupted": "Interrupted"
        case "error": "Error"
        default: "Idle"
        }
    }

    private var statusTone: BadgeTone {
        switch thread.status {
        case "busy": .success
        case "interrupted": .warning
        case "error": .danger
        default: .neutral
        }
    }
}

// MARK: - Memory

private struct HomeMemorySection: View {
    let state: LoadState<MemorySummary>
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            SectionHeader(title: "Memory")
            switch state {
            case .idle, .loading:
                HomeSkeleton(height: 112)
            case .failed(let error):
                HomeErrorCard(
                    title: "Couldn't load memory",
                    message: error.errorDescription ?? "Something went wrong.",
                    onRetry: onRetry
                )
            case .loaded(let summary):
                if summary.factCount == 0 {
                    HomeEmptyState(
                        title: "No memories yet",
                        message: "Facts you teach WaifuClaw will appear here."
                    )
                } else {
                    HomeMemoryCard(summary: summary)
                }
            }
        }
    }
}

private struct HomeMemoryCard: View {
    let summary: MemorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("\(summary.factCount) facts")
                .font(.title2)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            if !summary.topCategories.isEmpty {
                Text(
                    summary.topCategories
                        .map { "\($0.category) · \($0.count)" }
                        .joined(separator: "   ")
                )
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            }
            if let latest = summary.latestFact {
                Text(latest)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summary.factCount) memory facts."
                + (summary.latestFact.map { " Latest: \($0)" } ?? "")
        )
    }
}

// MARK: - State components (GAP-04/05/07 specs, inline)

/// Loading skeleton: static Theme.surface block. Static (no shimmer) so
/// Reduce Motion needs no special-casing.
private struct HomeSkeleton: View {
    let height: Double

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusM)
            .fill(Theme.surface)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Empty state: title + honest explanation. CTA only when it does something
/// real — none of Home's empty states have one, so none is rendered.
private struct HomeEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .center, spacing: Theme.spacingS) {
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
        .themeCard()
        .accessibilityElement(children: .combine)
    }
}

/// Loud error card: danger rail + what failed + Retry. Never blank, never
/// silent — every failure on this screen funnels through here.
private struct HomeErrorCard: View {
    let title: String
    let message: String
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Label {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
            Button("Retry", action: onRetry)
                .themePrimaryButton()
        }
        .themeCard()
        .overlay(alignment: .leading) {
            Theme.danger
                .frame(width: 4)
                .padding(.vertical, Theme.spacingM)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message). Activate Retry to try again.")
    }
}

// MARK: - Previews (every loud-failure state, via the real view model)

#Preview("Home — loaded") {
    HomeView(
        viewModel: HomeViewModel(data: MockDashboardData(mode: .loaded, userName: "Alex")),
        onViewAllThreads: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Home — empty") {
    HomeView(
        viewModel: HomeViewModel(data: MockDashboardData(mode: .empty, userName: "Alex")),
        onViewAllThreads: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Home — error") {
    HomeView(
        viewModel: HomeViewModel(data: MockDashboardData(mode: .error, userName: "Alex")),
        onViewAllThreads: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Home — offline") {
    HomeView(
        viewModel: HomeViewModel(data: MockDashboardData(mode: .offline, userName: "Alex")),
        onViewAllThreads: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Home — unpaired") {
    HomeView(
        viewModel: HomeViewModel(data: UnpairedDashboardData(userName: "Alex")),
        onViewAllThreads: {}
    )
    .preferredColorScheme(.dark)
}
