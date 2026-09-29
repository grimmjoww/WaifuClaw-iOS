import SwiftUI

// MARK: - Team board (leaf 1.4.2)
//
// The Team tab: Willie's call — the CONVERSATIONAL agent-to-agent surface is
// the primary view, the kanban board secondary (segmented switch). Contract
// §6 (REDESIGN-CONTRACT.md) is the layout authority.
//
// Data: consumes the `TeamData` protocol only (leaf 1.4.1) — never
// APIClient. Previews use `MockTeamData`; the App-integration leaf (1.6.1)
// injects the live provider and wraps this view in its NavigationStack.
//
// HONESTY (leaf 1.4.1 backend verification):
// - LIVE-BACKED: roster, conversations, messages, inbox snippets.
// - MOCK-ONLY: board / tasks / task detail / milestones / presence — the
//   backend has no task system or presence feed. Live board() returns
//   .empty and taskDetail(id:) throws .notSupported, so the board renders
//   a real empty state, never fake cards.
// - No message composer here: TeamData exposes no send method, and the real
//   send path (streaming chat) belongs to the Chat feature. The
//   conversation view is read-only over live messages, with an optional
//   "Continue in Chat" bridge that 1.6.1 wires — nil means no dead button.
//   (The small circular send arrow lives in Chat's composer, which this
//   leaf does not own.)
//
// Willie's three questions:
//   1. Buttons: the segment switches views (real), chips filter columns
//      (real), cards and rows navigate (real), Retry retries (real),
//      "Continue in Chat" exists only when 1.6.1 wires it. The Inbox has
//      no "View all" button — the Conversations tab IS the full list.
//   2. Visible feedback: skeletons crossfade to content; the segment
//      switch is instant; pull-to-refresh spins until loads settle.
//   3. Loud failure: per-section error cards + Retry; a refresh that fails
//      with older data on screen keeps the data and raises a warning
//      banner — never a blank screen, never silent.

// MARK: - Segment

/// Which Team surface is showing. Conversations first: Willie's call.
enum TeamSegment: String, CaseIterable, Identifiable {
    case conversations = "Conversations"
    case board = "Board"

    var id: String { rawValue }
}

// MARK: - View model

/// Owns Team-tab load state. Depends on `TeamData` only — never on
/// APIClient — so previews and the App-integration leaf can swap
/// mock/live sources freely. Sections load independently: one failing
/// endpoint degrades its own section, never the whole tab.
@Observable
@MainActor
final class TeamBoardViewModel {
    /// What one section is showing right now.
    enum Phase: Equatable {
        case loading
        case ready
        case error(TeamError)
    }

    private(set) var membersPhase: Phase = .loading
    private(set) var conversationsPhase: Phase = .loading
    private(set) var inboxPhase: Phase = .loading
    private(set) var milestonesPhase: Phase = .loading
    private(set) var boardPhase: Phase = .loading

    private(set) var members: [TeamMember] = []
    private(set) var conversations: [TeamConversation] = []
    private(set) var inboxItems: [InboxItem] = []
    private(set) var milestones: [Milestone] = []
    private(set) var board: TeamBoard = .empty

    /// Set when a refresh fails but older data is still on screen — the
    /// stale content stays usable and the failure is loud (banner), never
    /// silent and never a blank screen.
    private(set) var refreshNotice: String?

    /// Stored as a Sendable existential so the nonisolated init below is
    /// provably safe (same pattern as RunsListViewModel / BYOKViewModel).
    let dataSource: any TeamData & Sendable
    /// Monotonic generation: a cancelled or superseded load can never
    /// overwrite newer state, even if cancellation lands between its
    /// last await and its assignment.
    private var generation = 0
    private var boardLoaded = false

    /// Nonisolated so SwiftUI views can construct the model in their own
    /// (nonisolated) initializers; the init only stores the data source.
    nonisolated init(data: any TeamData & Sendable) {
        self.dataSource = data
    }

    /// Active threads first, then newest — the conversational view leads
    /// with the work that's actually happening.
    var sortedConversations: [TeamConversation] {
        conversations.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            let lhs = $0.updatedAt ?? .distantPast
            let rhs = $1.updatedAt ?? .distantPast
            return lhs > rhs
        }
    }

    var totalTaskCount: Int {
        board.columns.reduce(0) { $0 + $1.count }
    }

    /// (Re)loads the Conversations-tab sections: roster, threads, inbox,
    /// milestones. Safe to call from .task, .refreshable, and Retry.
    func refreshPrimary() async {
        generation += 1
        let current = generation
        refreshNotice = nil
        if members.isEmpty { membersPhase = .loading }
        if conversations.isEmpty { conversationsPhase = .loading }
        if inboxItems.isEmpty { inboxPhase = .loading }
        if milestones.isEmpty { milestonesPhase = .loading }

        // Sendable local so the @Sendable capture closures below don't
        // need to touch self (MainActor-isolated) off-actor.
        let source = dataSource
        async let membersResult = capture { try await source.members() }
        async let conversationsResult = capture { try await source.conversations(limit: 30) }
        async let inboxResult = capture { try await source.inboxItems(limit: 5) }
        async let milestonesResult = capture { try await source.milestones() }
        let results = await (membersResult, conversationsResult, inboxResult, milestonesResult)
        guard isCurrent(current) else { return }

        apply(results.0, to: \.members, phase: \.membersPhase, current: current)
        apply(results.1, to: \.conversations, phase: \.conversationsPhase, current: current)
        apply(results.2, to: \.inboxItems, phase: \.inboxPhase, current: current)
        apply(results.3, to: \.milestones, phase: \.milestonesPhase, current: current)
    }

    /// (Re)loads the kanban board. Lazy: only called when the Board segment
    /// is first selected (the board is the secondary surface).
    func refreshBoard() async {
        generation += 1
        let current = generation
        let hadBoard = boardLoaded
        if !hadBoard { boardPhase = .loading }
        do {
            let fetched = try await dataSource.board()
            guard isCurrent(current) else { return }
            board = fetched
            boardLoaded = true
            boardPhase = .ready
        } catch is CancellationError {
            // Normal lifecycle — never mapped to a UI error.
            return
        } catch {
            guard isCurrent(current) else { return }
            if hadBoard {
                refreshNotice = "Couldn't refresh the board — showing older data."
            } else {
                boardPhase = .error(mapTeamError(error))
            }
        }
    }

    // MARK: - Private

    /// Runs one fetch off-actor and boxes the outcome, so a single failing
    /// section can't take down its siblings in the async-let fan-out.
    /// CancellationError is rethrown, never boxed: callers treat it as
    /// lifecycle, not failure.
    private func capture<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> Result<T, Error> {
        do {
            return .success(try await work())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }

    private func apply<T>(
        _ result: Result<T, Error>,
        to values: ReferenceWritableKeyPath<TeamBoardViewModel, [T]>,
        phase: ReferenceWritableKeyPath<TeamBoardViewModel, Phase>,
        current: Int
    ) {
        switch result {
        case .success(let value):
            self[keyPath: values] = value
            self[keyPath: phase] = .ready
        case .failure(let error):
            if self[keyPath: values].isEmpty {
                self[keyPath: phase] = .error(mapTeamError(error))
            } else {
                // Stale data stays; the failure is loud via the banner.
                refreshNotice = "Couldn't refresh — showing older data."
            }
        }
    }

    private func isCurrent(_ value: Int) -> Bool {
        value == generation
    }
}

/// Maps transport errors to loud, actionable team errors.
/// CancellationError never reaches here — callers filter it first.
private func mapTeamError(_ error: Error) -> TeamError {
    (error as? TeamError) ?? TeamError.describe(error)
}

// MARK: - TeamBoardView

/// The Team tab. Mounted by leaf 1.6.1 inside its NavigationStack:
/// `TeamBoardView(data: LiveTeamData(...))`, optionally with
/// `onContinueInChat:` to bridge a conversation into the Chat tab.
struct TeamBoardView: View {
    @State private var viewModel: TeamBoardViewModel
    @State private var segment: TeamSegment
    @State private var selectedColumn: TaskColumn = .inbox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opens a thread in the Chat tab. Nil (default) = no button is
    /// rendered — never a dead control (Willie's question 1).
    private let onContinueInChat: ((String) -> Void)?

    init(
        data: any TeamData & Sendable,
        onContinueInChat: ((String) -> Void)? = nil,
        initialSegment: TeamSegment = .conversations
    ) {
        _viewModel = State(initialValue: TeamBoardViewModel(data: data))
        self.onContinueInChat = onContinueInChat
        _segment = State(initialValue: initialSegment)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Team view", selection: $segment) {
                ForEach(TeamSegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityLabel("Team view")
            .onChange(of: segment) { _, newValue in
                if newValue == .board {
                    Task { await viewModel.refreshBoard() }
                }
            }

            if let notice = viewModel.refreshNotice {
                TeamNoticeBanner(text: notice)
            }

            switch segment {
            case .conversations:
                conversationsTab
            case .board:
                boardTab
            }
        }
        .background(Theme.background)
        .navigationBarHidden(true)
        .task {
            await viewModel.refreshPrimary()
        }
        .refreshable {
            await viewModel.refreshPrimary()
            if segment == .board {
                await viewModel.refreshBoard()
            }
        }
    }

    // MARK: - Conversations tab (primary)

    /// Dimensional title + subheadline from contract §6.
    private var conversationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Team")
                        .themeDisplayText()
                    Text("Coordinate greatness.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)

                agentsRail
                conversationsSection
                inboxSection
                milestonesSection
            }
            .padding(.vertical, 16)
        }
    }

    /// Active Agents: horizontal avatar scroll (contract §6). 44pt
    /// medallions + micro names. Presence badges only when the backend
    /// actually knows (live presence is `.unknown` — shown as no badge,
    /// never a fabricated "Online").
    private var agentsRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Active Agents")
                .padding(.horizontal, 16)
            switch viewModel.membersPhase {
            case .loading:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<6, id: \.self) { _ in
                            TeamMedallionSkeleton()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .accessibilityLabel("Loading agents")
            case .ready:
                if viewModel.members.isEmpty {
                    Text("No agents registered on your computer.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .accessibilityLabel("No agents")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(viewModel.members) { member in
                                AgentMedallion(member: member)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            case .error(let error):
                TeamErrorCard(error: error) {
                    Task { await viewModel.refreshPrimary() }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Conversations")
                .padding(.horizontal, 16)
            switch viewModel.conversationsPhase {
            case .loading:
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        TeamRowSkeleton()
                    }
                }
                .padding(.horizontal, 16)
                .accessibilityLabel("Loading conversations")
            case .ready:
                if viewModel.sortedConversations.isEmpty {
                    TeamEmptyState(
                        title: "No conversations yet",
                        message: "When your agents start talking to each other, their threads show up here."
                    )
                    .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.sortedConversations) { conversation in
                            NavigationLink(
                                destination: TeamConversationView(
                                    conversation: conversation,
                                    data: viewModel.dataSource,
                                    onContinueInChat: onContinueInChat
                                )
                            ) {
                                ConversationRow(conversation: conversation)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            case .error(let error):
                TeamErrorCard(error: error) {
                    Task { await viewModel.refreshPrimary() }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Team Inbox rows open their conversation (contract §6: rows open
    /// threads — the Conversations tab above IS the full list, so there is
    /// no separate "View all" button to kill or keep).
    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Team Inbox")
                .padding(.horizontal, 16)
            switch viewModel.inboxPhase {
            case .loading:
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        TeamRowSkeleton()
                    }
                }
                .padding(.horizontal, 16)
                .accessibilityLabel("Loading inbox")
            case .ready:
                if viewModel.inboxItems.isEmpty {
                    Text("Inbox zero. Enjoy it.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .accessibilityLabel("Inbox empty")
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.inboxItems) { item in
                            NavigationLink(
                                destination: TeamConversationView(
                                    conversation: TeamConversation(
                                        id: item.id,
                                        title: item.title,
                                        status: .unknown(""),
                                        updatedAt: item.updatedAt,
                                        createdAt: nil
                                    ),
                                    data: viewModel.dataSource,
                                    onContinueInChat: onContinueInChat
                                )
                            ) {
                                InboxRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            case .error(let error):
                TeamErrorCard(error: error) {
                    Task { await viewModel.refreshPrimary() }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Milestones are mock-only (no backend feed): the section hides
    /// entirely when there's nothing to show — never placeholder tiles.
    @ViewBuilder
    private var milestonesSection: some View {
        switch viewModel.milestonesPhase {
        case .loading:
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Milestones")
                    .padding(.horizontal, 16)
                Text("Loading milestones…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
            }
            .accessibilityLabel("Loading milestones")
        case .ready:
            if !viewModel.milestones.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Milestones")
                        .padding(.horizontal, 16)
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(viewModel.milestones) { milestone in
                            StatTile(
                                systemImage: "trophy",
                                value: milestone.title,
                                label: milestone.subtitle
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        case .error:
            // A failed milestones load degrades silently-by-design here:
            // milestones are decorative, mock-only data — the error card
            // would be noise. The section simply doesn't render.
            EmptyView()
        }
    }

    // MARK: - Board tab (secondary)

    private var boardTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board")
                        .themeDisplayText()
                    Text("Coordinate greatness.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)

                switch viewModel.boardPhase {
                case .loading:
                    VStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            TeamRowSkeleton()
                        }
                    }
                    .padding(.horizontal, 16)
                    .accessibilityLabel("Loading board")
                case .ready:
                    boardContent
                case .error(let error):
                    TeamErrorCard(error: error) {
                        Task { await viewModel.refreshBoard() }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
        }
    }

    /// FilterChip column picker with counts (contract §6, GAP-01 spec):
    /// one column's cards listed below.
    private var boardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskColumn.allCases, id: \.self) { column in
                        TeamFilterChip(
                            title: "\(column.title) (\(viewModel.board.tasks(in: column).count))",
                            selected: selectedColumn == column
                        ) {
                            selectedColumn = column
                        }
                        .accessibilityLabel(
                            "\(column.title), \(viewModel.board.tasks(in: column).count) tasks, \(selectedColumn == column ? "selected" : "not selected")"
                        )
                    }
                }
                .padding(.horizontal, 16)
            }

            let tasks = viewModel.board.tasks(in: selectedColumn)
            if tasks.isEmpty {
                TeamEmptyState(
                    title: viewModel.totalTaskCount == 0 ? "The board is empty" : "No tasks in \(selectedColumn.title)",
                    message: viewModel.totalTaskCount == 0
                        ? "Task tracking lives on the desktop roadmap — the board is a preview until your computer ships a task feed."
                        : "Nothing parked here right now."
                )
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 12) {
                    ForEach(tasks) { task in
                        NavigationLink(destination: TeamTaskDetailView(task: task, data: viewModel.dataSource)) {
                            TaskCard(task: task)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func retryPrimary() {
        Task { await viewModel.refreshPrimary() }
    }
}

// MARK: - Agent medallion (in-file)

/// 44pt agent medallion (contract §6): initials monogram in the Phantom
/// Horizons accent until the bespoke agent-medallion art (§11) lands.
/// Presence badge only when known — live presence is `.unknown`, shown as
/// no badge, never a fabricated "Online".
private struct AgentMedallion: View {
    let member: TeamMember

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Theme.magenta.opacity(0.18))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(initials)
                            .font(.headline)
                            .bold()
                            .foregroundStyle(Theme.magentaSoft)
                    }
                if member.presence != .unknown {
                    Circle()
                        .fill(presenceColor)
                        .frame(width: 12, height: 12)
                        .overlay {
                            Circle().stroke(Theme.background, lineWidth: 2)
                        }
                        .accessibilityHidden(true)
                }
            }
            Text(member.displayName)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 56)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agentLabel)
    }

    private var initials: String {
        let words = member.displayName.split(separator: " ")
        let letters = words.prefix(2).map { String($0.prefix(1)).uppercased() }
        let joined = letters.joined()
        return joined.isEmpty ? "?" : joined
    }

    private var presenceColor: Color {
        switch member.presence {
        case .online: Theme.success
        case .busy: Theme.warning
        case .offline: Theme.textSecondary
        case .unknown: Theme.textSecondary
        }
    }

    private var agentLabel: String {
        if member.presence == .unknown {
            return member.displayName
        }
        return "\(member.displayName), \(member.presence.badgeText)"
    }
}

private struct TeamMedallionSkeleton: View {
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Theme.track)
                .frame(width: 44, height: 44)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.track)
                .frame(width: 40, height: 10)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Conversation row (in-file)

/// One agent-to-agent thread row: title, status badge, relative time.
/// One VoiceOver element.
private struct ConversationRow: View {
    let conversation: TeamConversation
    private let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if let updated = conversation.updatedAt {
                        Text(relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                StatusBadge(text: conversation.status.badgeText, tone: statusTone)
            }
        }
        .padding(12)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.displayTitle), \(conversation.status.badgeText)")
    }

    private var statusTone: BadgeTone {
        switch conversation.status {
        case .busy: .success
        case .interrupted: .warning
        case .error: .danger
        case .idle, .unknown: .neutral
        }
    }
}

// MARK: - Inbox row (in-file)

/// Team Inbox row (contract §6): 36pt medallion + name + 2-line snippet +
/// micro time. Tapping opens the conversation.
private struct InboxRow: View {
    let item: InboxItem
    private let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.magenta.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String(item.title.prefix(1)).uppercased())
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(Theme.magentaSoft)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let snippet = item.snippet {
                    Text(snippet)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let updated = item.updatedAt {
                Text(relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inbox: \(item.title)")
    }
}

// MARK: - Task card (in-file)

/// Kanban card (contract §6): title, #id · agent, priority badge.
/// 44pt+ tap target via the card itself.
private struct TaskCard: View {
    let task: TeamTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack {
                Text("#\(task.id) · \(task.assignee)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                StatusBadge(text: task.priority.badgeText, tone: priorityTone)
            }
        }
        .padding(12)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.priority.badgeText) priority, assigned to \(task.assignee)")
    }

    private var priorityTone: BadgeTone {
        switch task.priority {
        case .critical: .danger
        case .high: .warning
        case .medium: .info
        case .low, .unknown: .neutral
        }
    }
}

// MARK: - Filter chip (GAP-01 spec, in-file)

/// Selectable capsule per GAP-01: 44pt min height, selected = magenta bg +
/// white bold text, unselected = surface bg + secondary text + hairline
/// border. A real Button, never onTapGesture.
private struct TeamFilterChip: View {
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
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Error card (GAP-07 spec, in-file)

/// Loud failure card: danger rail, what failed, and a real Retry button.
/// Announced as a unit to VoiceOver.
private struct TeamErrorCard: View {
    let error: TeamError
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Theme.danger.frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Couldn't load this section.")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                }
                Text(error.errorDescription ?? "Something went wrong.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("Retry", action: onRetry)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)
                    .background(Theme.magenta)
                    .clipShape(Capsule())
                    .accessibilityLabel("Retry loading this section")
            }
            .padding(16)
        }
        .themeCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state (GAP-04 spec, in-file)

/// Honest empty state: title + explanation. No CTA button — there is no
/// "create task" or "start thread" endpoint, so a button would be an
/// orphan capability.
private struct TeamEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                .padding(.top, 32)
                .accessibilityHidden(true)
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

// MARK: - Notice banner (GAP-08 spec, in-file)

/// Inline warning banner: stale data is still on screen and the refresh
/// failed loudly — never a silent failure, never a blank screen.
private struct TeamNoticeBanner: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.warning)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Skeleton rows (GAP-05 spec, in-file)

/// Loading placeholders matching the row shapes. Static blocks (no
/// shimmer) — static is also what Reduce Motion requires.
private struct TeamRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.track)
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.track)
                .frame(width: 140, height: 12)
        }
        .padding(12)
        .themeCard()
        .accessibilityHidden(true)
    }
}

// MARK: - Conversation detail (in-file)
//
// Dedicated screen is the standard iOS pattern for opening a thread, and
// the leaf owns exactly two files — so the conversation screen lives here
// as a private type rather than a third file. Leaf 1.6.1 may split it out.
// Read-only over live messages: TeamData exposes no send method, and the
// real send path (streaming chat) belongs to the Chat feature.

/// Loads one thread's live messages.
@Observable
@MainActor
private final class TeamConversationLoader {
    enum Phase: Equatable {
        case loading
        case ready
        case error(TeamError)
    }

    private(set) var phase: Phase = .loading
    private(set) var messages: [TeamMessage] = []

    let dataSource: any TeamData & Sendable
    private let threadID: String
    private var generation = 0

    nonisolated init(data: any TeamData & Sendable, threadID: String) {
        self.dataSource = data
        self.threadID = threadID
    }

    func refresh() async {
        generation += 1
        let current = generation
        if messages.isEmpty {
            phase = .loading
        }
        do {
            let fetched = try await dataSource.messages(threadID: threadID, limit: 100)
            guard current == generation else { return }
            messages = fetched
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            if messages.isEmpty {
                phase = .error(mapTeamError(error))
            }
            // A refresh failure with messages on screen keeps them; the
            // list-level pull-to-refresh spinner already signaled the miss.
        }
    }
}

/// One agent-to-agent thread, read live. "Continue in Chat" bridges to the
/// Chat tab with thread context — rendered only when 1.6.1 wires the
/// handler, never a dead button.
private struct TeamConversationView: View {
    @State private var loader: TeamConversationLoader
    private let conversation: TeamConversation
    private let onContinueInChat: ((String) -> Void)?

    init(
        conversation: TeamConversation,
        data: any TeamData & Sendable,
        onContinueInChat: ((String) -> Void)? = nil
    ) {
        self.conversation = conversation
        _loader = State(initialValue: TeamConversationLoader(data: data, threadID: conversation.id))
        self.onContinueInChat = onContinueInChat
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch loader.phase {
                case .loading:
                    VStack(spacing: 12) {
                        ForEach(0..<5, id: \.self) { _ in
                            TeamRowSkeleton()
                        }
                    }
                    .accessibilityLabel("Loading messages")
                case .ready:
                    if loader.messages.isEmpty {
                        TeamEmptyState(
                            title: "No messages yet",
                            message: "This thread exists but nothing has been said in it."
                        )
                    } else {
                        ForEach(loader.messages) { message in
                            TeamMessageRow(message: message)
                        }
                    }
                case .error(let error):
                    TeamErrorCard(error: error) {
                        Task { await loader.refresh() }
                    }
                }

                if let onContinueInChat {
                    Button {
                        onContinueInChat(conversation.id)
                    } label: {
                        Label("Continue in Chat", systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline)
                            .bold()
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .background(Theme.magenta)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Continue this thread in Chat")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loader.refresh()
        }
        .refreshable {
            await loader.refresh()
        }
    }
}

/// One turn in the conversation: who said it + what they said. Tool and
/// system traffic is visually quieter; the role is always labeled, never
/// color-only.
private struct TeamMessageRow: View {
    let message: TeamMessage
    private let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadge(text: authorLabel, tone: roleTone)
                if let created = message.createdAt {
                    Text(relativeFormatter.localizedString(for: created, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            Text(message.displayText)
                .font(.body)
                .foregroundStyle(message.role == .tool ? Theme.textSecondary : Theme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(12)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(authorLabel): \(message.displayText)")
    }

    private var authorLabel: String {
        if let author = message.authorName, !author.isEmpty {
            return author
        }
        return message.role.badgeText
    }

    private var roleTone: BadgeTone {
        switch message.role {
        case .user: .info
        case .agent: .success
        case .tool: .neutral
        case .system, .unknown: .warning
        }
    }
}

// MARK: - Previews

#Preview("Conversations loaded") {
    NavigationStack {
        TeamBoardView(data: MockTeamData(mode: .loaded))
    }
    .preferredColorScheme(.dark)
}

#Preview("Board loaded") {
    NavigationStack {
        TeamBoardView(data: MockTeamData(mode: .loaded), initialSegment: .board)
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack {
        TeamBoardView(data: MockTeamData(mode: .empty))
    }
    .preferredColorScheme(.dark)
}

#Preview("Error") {
    NavigationStack {
        TeamBoardView(data: MockTeamData(mode: .error))
    }
    .preferredColorScheme(.dark)
}
