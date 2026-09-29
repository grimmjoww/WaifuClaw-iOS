import SwiftUI

// MARK: - Filter

/// Session-list filter chips: All / Active / Past.
private enum SessionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case past = "Past"

    var id: String { rawValue }

    func matches(_ status: RunStatus) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            status == .running || status == .pending
        case .past:
            !(status == .running || status == .pending)
        }
    }
}

// MARK: - Session list

/// The Sessions tab root: active and past agent sessions (runs), newest
/// first. Tapping a row pushes the read-only session detail. Expects to live
/// inside a NavigationStack (provided by the App-integration leaf).
struct SessionListView: View {
    @State private var viewModel: SessionListViewModel
    @State private var filter: SessionFilter = .all

    /// `sessionData` is threaded through to each pushed detail view.
    private let sessionData: any SessionData & Sendable

    /// - Parameters:
    ///   - runsData: the session source. `MockRunsData(mode:)` in previews;
    ///     the live provider in the real app (leaf 1.6.1).
    ///   - sessionData: the per-session source for pushed detail views.
    init(runsData: any RunsData & Sendable, sessionData: any SessionData & Sendable) {
        _viewModel = State(initialValue: SessionListViewModel(runsData: runsData))
        self.sessionData = sessionData
    }

    private var filteredSessions: [RunSummary] {
        viewModel.sessions.filter { filter.matches($0.status) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingL) {
                    titleView
                    switch viewModel.phase {
                    case .loading:
                        skeletonList
                    case .error(let message):
                        SessionErrorCard(title: "Couldn't load sessions", message: message) {
                            Task { await viewModel.refresh() }
                        }
                        .padding(.horizontal, Theme.spacingL)
                    case .ready:
                        readyContent
                    }
                }
                .padding(.vertical, Theme.spacingS)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Title

    private var titleView: some View {
        Text("Sessions")
            .themeDisplayText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.spacingL)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Ready state

    @ViewBuilder
    private var readyContent: some View {
        if viewModel.sessions.isEmpty {
            SessionEmptyState(
                title: "No sessions yet.",
                message: "Sessions appear here when your desktop starts an agent run."
            )
            .padding(.horizontal, Theme.spacingL)
        } else {
            filterChips
            if filteredSessions.isEmpty {
                SessionEmptyState(
                    title: "No sessions match this filter.",
                    message: "Try a different filter — nothing is hidden, just filtered out."
                )
                .padding(.horizontal, Theme.spacingL)
            } else {
                sessionRows
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                ForEach(SessionFilter.allCases) { option in
                    let selected = filter == option
                    Button {
                        filter = option
                    } label: {
                        Text(option.rawValue)
                            .font(Theme.caption)
                            .bold()
                            .padding(.horizontal, Theme.spacingL)
                            .padding(.vertical, Theme.spacingS)
                            .background(selected ? Theme.magenta : Theme.surface)
                            .foregroundStyle(selected ? .white : Theme.textSecondary)
                            .clipShape(Capsule())
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("\(option.rawValue) sessions filter")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.spacingL)
        }
    }

    private var sessionRows: some View {
        LazyVStack(spacing: Theme.spacingS) {
            ForEach(filteredSessions) { session in
                NavigationLink {
                    SessionDetailView(summary: session, data: sessionData)
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.spacingL)
    }

    private func sessionRow(_ session: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text(session.displayObjective)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: Theme.spacingS) {
                StatusBadge(text: session.status.badgeText, tone: SessionListView.tone(for: session.status))
                if let stepText = session.stepText {
                    Text(stepText)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let updated = session.updatedAt {
                    Text(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.displayObjective), \(session.status.badgeText)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityHint("Opens the read-only session view.")
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func tone(for status: RunStatus) -> BadgeTone {
        switch status {
        case .running:
            .success
        case .pending:
            .warning
        case .success:
            .success
        case .error, .timeout:
            .danger
        case .interrupted, .unknown:
            .neutral
        }
    }

    // MARK: - Loading skeleton

    private var skeletonList: some View {
        VStack(spacing: Theme.spacingS) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .fill(Theme.surface)
                    .frame(height: 76)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.spacingL)
        .accessibilityLabel("Loading sessions")
    }
}

// MARK: - Shared session states

/// Honest empty state: title + what-to-do message, never a silent blank.
struct SessionEmptyState: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Theme.spacingS) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingXXL)
        .accessibilityElement(children: .combine)
    }
}

/// Loud failure card (contract GAP-07 spec): themeCard + danger left rail +
/// title + message + Retry. Failures are never silent.
struct SessionErrorCard: View {
    var title: String
    var message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Theme.danger
                .frame(width: 4)
                .clipShape(.rect(cornerRadius: 2))
                .padding(.trailing, Theme.spacingM)
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                Text(title)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                Button("Retry", action: onRetry)
                    .font(Theme.headline)
                    .frame(minHeight: 44)
                    .accessibilityHint("Tries loading again.")
            }
            Spacer()
        }
        .themeCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}

#Preview("Loaded") {
    NavigationStack {
        SessionListView(runsData: MockRunsData(mode: .loaded), sessionData: MockSessionData())
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack {
        SessionListView(runsData: MockRunsData(mode: .empty), sessionData: MockSessionData())
    }
    .preferredColorScheme(.dark)
}

#Preview("Error") {
    NavigationStack {
        SessionListView(runsData: MockRunsData(mode: .error), sessionData: MockSessionData())
    }
    .preferredColorScheme(.dark)
}
