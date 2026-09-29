import SwiftUI

// MARK: - Task detail (leaf 1.4.2)
//
// Contract §7 (REDESIGN-CONTRACT.md) is the layout authority. Every section
// present on TeamTaskDetail renders; absent data hides its section — never
// placeholder text.
//
// HONESTY: TeamTaskDetail is MOCK-ONLY (leaf 1.4.1 verification — no backend
// task system). Live taskDetail(id:) throws .notSupported loudly; with the
// live board always empty there is no card to tap, so this screen is only
// reachable over mock data until the desktop ships a task feed.
// The contract's "Message agent" action is CONDITIONAL on thread-context
// support and is killed in this leaf's scope: the conversational Team
// surface (TeamBoardView) is the primary view and owns the optional
// "Continue in Chat" bridge. No dead buttons here (Willie's question 1).
//
// Willie's three questions:
//   1. Buttons: none on this screen — it is informational, and the one
//      conditional action is killed rather than faked. Retry retries.
//   2. Visible feedback: skeleton → content; pull-to-refresh spins until
//      the load settles.
//   3. Loud failure: full error card + Retry on load failure.

// MARK: - View model

/// Loads one task's detail via `TeamData.taskDetail(id:)`.
@Observable
@MainActor
final class TeamTaskDetailViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case error(TeamError)
    }

    private(set) var phase: Phase = .loading
    private(set) var detail: TeamTaskDetail?

    let dataSource: any TeamData & Sendable
    private let taskID: String
    private var generation = 0

    /// Nonisolated so SwiftUI views can construct the model in their own
    /// (nonisolated) initializers; the init only stores its inputs.
    nonisolated init(data: any TeamData & Sendable, taskID: String) {
        self.dataSource = data
        self.taskID = taskID
    }

    func refresh() async {
        generation += 1
        let current = generation
        if detail == nil {
            phase = .loading
        }
        do {
            let fetched = try await dataSource.taskDetail(id: taskID)
            guard current == generation else { return }
            detail = fetched
            phase = .ready
        } catch is CancellationError {
            // Normal lifecycle — never mapped to a UI error.
            return
        } catch {
            guard current == generation else { return }
            if detail == nil {
                phase = .error((error as? TeamError) ?? TeamError.describe(error))
            }
        }
    }
}

// MARK: - TeamTaskDetailView

/// Task detail screen. Mounted from the board's cards:
/// `TeamTaskDetailView(task: task, data: dataSource)` inside a
/// NavigationStack (leaf 1.6.1).
struct TeamTaskDetailView: View {
    @State private var viewModel: TeamTaskDetailViewModel
    private let task: TeamTask

    init(task: TeamTask, data: any TeamData & Sendable) {
        self.task = task
        _viewModel = State(initialValue: TeamTaskDetailViewModel(data: data, taskID: task.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch viewModel.phase {
                case .loading:
                    TeamTaskDetailSkeleton()
                        .accessibilityLabel("Loading task detail")
                case .ready:
                    if let detail = viewModel.detail {
                        detailContent(detail)
                    }
                case .error(let error):
                    TeamTaskDetailErrorCard(error: error) {
                        Task { await viewModel.refresh() }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Task #\(task.id)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Content (contract §7)

    @ViewBuilder
    private func detailContent(_ detail: TeamTaskDetail) -> some View {
        // 1. Title + priority badge + risk badges.
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.task.title)
                .font(.title2)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                StatusBadge(text: detail.task.priority.badgeText, tone: priorityTone(detail.task.priority))
                ForEach(detail.riskBadges, id: \.self) { risk in
                    StatusBadge(text: risk, tone: .danger)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(detail.task.title), \(detail.task.priority.badgeText) priority")

        // 2. Progress card — only when the backend (or mock) reports it.
        if let progress = detail.progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(Theme.magentaSoft)
                }
                ProgressBar(value: progress)
                Text("Verifications \(detail.verificationText) · Reviewers \(detail.reviewerText)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .themeCard()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Progress \(Int((progress * 100).rounded())) percent. Verifications \(detail.verificationText). Reviewers \(detail.reviewerText).")
        }

        // 3. Details card — rows render only when the value exists.
        let detailRows = buildDetailRows(detail)
        if !detailRows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details")
                    .font(.headline)
                    .bold()
                    .foregroundStyle(Theme.textPrimary)
                ForEach(detailRows) { row in
                    TaskDetailRow(label: row.label, value: row.value, mono: row.mono)
                }
            }
            .padding(16)
            .themeCard()
        }

        // 4. OutcomeRun mini-status — the step line, when the feed has one.
        // No TimelineDots: the model carries text, not step states, and
        // dots invented from a string would be decoration, not data.
        if let outcome = detail.outcomeStepText, !outcome.isEmpty {
            HStack(spacing: 12) {
                TimelineDot(index: 1, state: .current)
                    .accessibilityHidden(true)
                Text(outcome)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(16)
            .themeCard()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Outcome: \(outcome)")
        }
    }

    /// Assembles the details-card rows, skipping nil values so absent data
    /// hides its row instead of showing a placeholder.
    private func buildDetailRows(_ detail: TeamTaskDetail) -> [TaskDetailRowData] {
        var rows: [TaskDetailRowData] = []
        if let threadID = detail.task.threadID {
            // The backing conversation — the seam the conversational view uses.
            rows.append(TaskDetailRowData(label: "Thread", value: threadID, mono: true))
        }
        rows.append(contentsOf: optionalRows(detail))
        rows.append(TaskDetailRowData(label: "Assignee", value: detail.task.assignee, mono: false))
        return rows
    }

    private func optionalRows(_ detail: TeamTaskDetail) -> [TaskDetailRowData] {
        var rows: [TaskDetailRowData] = []
        if let branch = detail.branch {
            rows.append(TaskDetailRowData(label: "Branch", value: branch, mono: true))
        }
        if let hash = detail.frozenHash {
            rows.append(TaskDetailRowData(label: "Frozen", value: hash, mono: true))
        }
        return rows
    }

    private func priorityTone(_ priority: TaskPriority) -> BadgeTone {
        switch priority {
        case .critical: .danger
        case .high: .warning
        case .medium: .info
        case .low, .unknown: .neutral
        }
    }
}

// MARK: - Detail rows (in-file)

private struct TaskDetailRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let mono: Bool
}

/// Label/value row. Combined into one VoiceOver element.
private struct TaskDetailRow: View {
    let label: String
    let value: String
    let mono: Bool

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Error card (GAP-07 spec, in-file)

private struct TeamTaskDetailErrorCard: View {
    let error: TeamError
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Theme.danger.frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Couldn't load this task.")
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
                    .accessibilityLabel("Retry loading this task")
            }
            .padding(16)
        }
        .themeCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Skeleton (GAP-05 spec, in-file)

/// Static blocks matching the content shape — no shimmer (Reduce Motion).
private struct TeamTaskDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.track)
                .frame(height: 28)
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.track)
                .frame(width: 120, height: 24)
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.track)
                .frame(height: 120)
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.track)
                .frame(height: 140)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Task detail loaded") {
    NavigationStack {
        TeamTaskDetailView(
            task: TeamTask(
                id: "653",
                title: "Hermes-Sage finalization",
                assignee: "Rei",
                priority: .high,
                column: .inProgress,
                threadID: "thread-hermes-sage",
                progress: 0.33
            ),
            data: MockTeamData(mode: .loaded)
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Task detail error") {
    NavigationStack {
        TeamTaskDetailView(
            task: TeamTask(
                id: "653",
                title: "Hermes-Sage finalization",
                assignee: "Rei",
                priority: .high,
                column: .inProgress,
                threadID: nil,
                progress: nil
            ),
            data: MockTeamData(mode: .error)
        )
    }
    .preferredColorScheme(.dark)
}
