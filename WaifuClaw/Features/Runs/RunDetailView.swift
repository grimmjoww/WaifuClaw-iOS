import SwiftUI

// MARK: - Run detail (leaf 1.3.3, contract §5)
//
// Detail screen for one run: header facts, step timeline, frozen candidate,
// verification evidence, risk tier, reviewer results, Kline note, and the
// sticky "Rollback to stable" bar.
//
// Endpoint honesty (verified by leaf 1.3.1 against thread_runs.py):
// - Rollback IS real: POST /api/threads/{t}/runs/{r}/cancel?action=rollback
//   (via Endpoints.Threads.cancelRun). Semantics: stop execution AND revert
//   THIS run's changes to the pre-run checkpoint — not an app version rollback.
// - Canary promotion: NO endpoint exists — the button is killed, not rendered.
// - Message-agent row: NO endpoint exists — the row is killed, not rendered.
// - Evidence / frozen candidate / reviewers / risk tier: mock-only types until
//   a backend feed exists; live providers return them empty/nil.
// - A/B Worker System card (contract §5 item 6): omitted — no worker-breakdown
//   data exists on RunDetail (live and mock both provide none). Rendering
//   static "Worker A / Supervisor / Worker B" labels would be fiction.
// - "View session" deep link (§8): omitted — the Session view is leaf 1.5.1's
//   work and does not exist yet. No fake navigation targets.

// MARK: - View model

/// Detail state for one run. Loads (and fails) independently of the list.
/// Follows the BYOKViewModel pattern: @Observable + @MainActor, owned by the
/// view via @State, nonisolated init so views can build it in init.
@Observable
@MainActor
final class RunDetailViewModel {
    /// Rollback lifecycle — the user sees every phase (Willie's question 2).
    enum RollbackPhase: Equatable {
        case idle
        case working
        case succeeded
        case failed(RunsError)
    }

    let run: RunSummary
    private let data: RunsData

    var detail: RunDetail?
    var isLoading = false
    var loadError: RunsError?
    /// A refresh failed but older data is on screen — network actions are
    /// disabled with an explanation, never silently tappable.
    var showingStaleData = false

    var confirmingRollback = false
    var rollbackPhase = RollbackPhase.idle
    private var rollbackTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    /// Nonisolated: the init only stores its inputs (both are value types or
    /// captured before isolation begins).
    nonisolated init(run: RunSummary, data: RunsData) {
        self.run = run
        self.data = data
    }

    /// Freshest known status — the list snapshot goes stale after rollback.
    var status: RunStatus {
        detail?.summary.status ?? run.status
    }

    /// Rollback is offered only while the run can actually be stopped.
    /// A terminal run would answer 409, so the bar is killed instead of fake.
    /// `.unknown` is excluded: we can't honestly claim the stop is safe.
    var canOfferRollback: Bool {
        switch status {
        case .pending, .running: true
        case .success, .error, .timeout, .interrupted, .unknown: false
        }
    }

    // MARK: Load

    /// Structured entry point for .task / .refreshable.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await fetchDetail()
    }

    /// Button-driven retry: cancels any in-flight load first.
    func retryLoad() {
        loadTask?.cancel()
        rollbackPhase = .idle
        loadTask = Task { await load() }
    }

    private func fetchDetail() async {
        do {
            detail = try await data.runDetail(threadID: run.threadID, runID: run.id)
            loadError = nil
            showingStaleData = false
        } catch is CancellationError {
            // View went away — normal lifecycle, never a UI error.
            return
        } catch {
            let mapped = RunsError.describe(error)
            if detail == nil {
                loadError = mapped
            } else {
                // Keep the cached detail on screen; say so loudly.
                showingStaleData = true
            }
        }
    }

    // MARK: Rollback (destructive — the view confirms before calling this)

    /// Starts the confirmed rollback. Cancels any in-flight attempt first.
    func startRollback() {
        confirmingRollback = false
        rollbackTask?.cancel()
        rollbackTask = Task { await performRollback() }
    }

    /// Re-opens the confirmation after a failure (destructive: confirm again).
    func retryRollback() {
        rollbackPhase = .idle
        confirmingRollback = true
    }

    private func performRollback() async {
        rollbackPhase = .working
        do {
            // wait=true blocks until the run fully stops; then refetch so the
            // terminal status retires the rollback bar on its own.
            try await data.cancelRun(threadID: run.threadID, runID: run.id, rollback: true)
            rollbackPhase = .succeeded
            await fetchDetail()
        } catch is CancellationError {
            rollbackPhase = .idle
            return
        } catch {
            rollbackPhase = .failed(RunsError.describe(error))
        }
    }
}

// MARK: - View

/// Run detail screen (contract §5). Created with the run to display plus the
/// data source that serves it; leaf 1.3.2 navigates here with a RunSummary.
struct RunDetailView: View {
    @State private var viewModel: RunDetailViewModel

    init(run: RunSummary, data: RunsData) {
        _viewModel = State(initialValue: RunDetailViewModel(run: run, data: data))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingM) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { await viewModel.load() }
        }
        .task { await viewModel.load() }
        .safeAreaInset(edge: .bottom) {
            if viewModel.canOfferRollback {
                rollbackBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.detail == nil {
            RunDetailSkeleton()
        } else if let detail = viewModel.detail {
            if viewModel.showingStaleData {
                staleBanner
            }
            if viewModel.rollbackPhase == .succeeded {
                rollbackSuccessBanner
            }
            header(summary: detail.summary)
            progressCard(detail)
            if let frozen = detail.frozenCandidate {
                frozenCard(frozen)
            }
            if !detail.evidence.isEmpty {
                evidenceCard(detail.evidence)
            }
            if detail.summary.riskTier != nil || !detail.riskBullets.isEmpty {
                riskCard(detail)
            }
            if !detail.reviewers.isEmpty {
                reviewersCard(detail.reviewers)
            }
            klineNote
            footer
            if case .failed(let error) = viewModel.rollbackPhase {
                RunDetailErrorCard(
                    title: "Rollback failed",
                    message: error.localizedDescription,
                    retryTitle: "Try again",
                    onRetry: viewModel.retryRollback
                )
            }
        } else if let error = viewModel.loadError {
            RunDetailErrorCard(
                title: "Couldn't load this run",
                message: error.localizedDescription,
                retryTitle: "Retry",
                onRetry: viewModel.retryLoad
            )
            .padding(.top, 24)
        }
    }

    // MARK: Header (contract §5 item 1)

    private func header(summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Text(summary.displayObjective)
                .font(.title2)
                .bold()
                .foregroundStyle(Theme.textPrimary)
            StatusBadge(text: summary.status.badgeText, tone: tone(for: summary.status))
        }
    }

    // MARK: Progress + timeline (contract §5 item 2)

    private func progressCard(_ detail: RunDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Text(stepHeadline(for: detail))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ProgressBar(value: progressValue(for: detail))
            if !detail.steps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(detail.steps) { step in
                            VStack(spacing: 4) {
                                TimelineDot(index: step.index + 1, state: timelineState(for: step.state))
                                Text(step.name)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(width: 64)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "Step \(step.index + 1) of \(detail.steps.count), \(step.name), \(stepStateName(step.state))"
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .themeCard()
    }

    // MARK: Frozen candidate (contract §5 item 3)

    private func frozenCard(_ frozen: FrozenCandidate) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            HStack {
                Text("Frozen Candidate")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StatusBadge(text: "FROZEN", tone: .info)
            }
            detailRow(label: "Hash", value: frozen.hash, mono: true)
            if let at = frozen.frozenAt {
                detailRow(label: "Frozen at", value: Self.dateFormatter.string(from: at))
            }
            detailRow(label: "Approvals", value: "\(frozen.approvals)/\(frozen.approvalsRequired)")
            detailRow(label: "Review state", value: frozen.reviewState)
        }
        .themeCard()
    }

    // MARK: Verification evidence (contract §5 item 4)

    private func evidenceCard(_ items: [VerificationEvidence]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Text("Verification Evidence")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: evidenceIcon(for: item.result))
                        .foregroundStyle(evidenceColor(for: item.result))
                        .accessibilityHidden(true)
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name): \(item.detail)")
            }
        }
        .themeCard()
    }

    // MARK: Risk tier (contract §5 item 5)

    private func riskCard(_ detail: RunDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            HStack {
                Text("Risk Tier")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let tier = detail.summary.riskTier {
                    StatusBadge(text: tier.badgeText, tone: riskTone(for: tier))
                }
            }
            ForEach(detail.riskBullets, id: \.self) { bullet in
                Label {
                    Text(bullet)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
            }
        }
        .themeCard()
    }

    // MARK: Reviewer results (contract §5 item 7)

    private func reviewersCard(_ reviewers: [ReviewerResult]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Text("Reviewer Results")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(reviewers) { reviewer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(reviewer.reviewerName)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        StatusBadge(text: reviewer.state, tone: reviewerTone(for: reviewer.state))
                    }
                    if let note = reviewer.note, !note.isEmpty {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(reviewer.reviewerName): \(reviewer.state)")
            }
        }
        .themeCard()
    }

    // MARK: Kline note (contract §5 item 8)

    private var klineNote: some View {
        HStack(spacing: 12) {
            KlineAvatar(diameter: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("“I won't call it done until the evidence is real.”")
                    .italic()
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("Current action: Implementing candidate.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Kline: I won't call it done until the evidence is real. Current action: Implementing candidate."
        )
    }

    // MARK: Footer (contract §5 item 9)

    private var footer: some View {
        Text("No approval binds to changed bytes.")
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    // MARK: Banners

    /// GAP-08-shaped offline strip (OfflineBanner doesn't exist yet as a
    /// component; this follows its spec: warning@15% + icon + message).
    private var staleBanner: some View {
        Label {
            Text("You're offline — showing last synced data.")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.15))
        .clipShape(.rect(cornerRadius: Theme.radiusM))
    }

    private var rollbackSuccessBanner: some View {
        Label {
            Text("Run stopped — its changes were reverted to the pre-run checkpoint.")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rollback succeeded. Run stopped, changes reverted to the pre-run checkpoint.")
    }

    // MARK: Sticky rollback bar (contract §5 item 10)

    private var rollbackBar: some View {
        VStack(spacing: 8) {
            if viewModel.showingStaleData {
                // Contract §5: offline actions disabled with explanation,
                // never silently tappable.
                Text("You're offline — rollback needs a connection.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                Button("Rollback to stable", systemImage: "arrow.uturn.backward") {
                    viewModel.confirmingRollback = true
                }
                .font(.headline)
                .bold()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.danger)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .disabled(viewModel.rollbackPhase == .working)
                .opacity(viewModel.rollbackPhase == .working ? 0.75 : 1)
                .accessibilityHint("Destructive. Stops the run and reverts its changes to the pre-run checkpoint.")
                .confirmationDialog(
                    "Roll back this run?",
                    isPresented: $viewModel.confirmingRollback,
                    titleVisibility: .visible
                ) {
                    // Attached to the triggering button (navigation.md).
                    Button("Roll back", role: .destructive, action: viewModel.startRollback)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This stops the run and reverts its changes to the pre-run checkpoint. This can't be undone.")
                }
                .overlay {
                    if viewModel.rollbackPhase == .working {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Rolling back…")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Rollback in progress")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.background)
    }

    // MARK: Rows

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: Mappings

    private func tone(for status: RunStatus) -> BadgeTone {
        switch status {
        case .pending, .unknown: .neutral
        case .running, .success: .success
        case .error: .danger
        case .timeout: .warning
        case .interrupted: .info
        }
    }

    private func timelineState(for state: RunStep.State) -> TimelineState {
        switch state {
        case .done: .done
        case .active: .current
        case .failed: .failed
        case .pending, .skipped: .pending
        }
    }

    private func stepStateName(_ state: RunStep.State) -> String {
        switch state {
        case .done: "done"
        case .active: "current"
        case .failed: "failed"
        case .pending: "pending"
        case .skipped: "skipped"
        }
    }

    private func evidenceIcon(for result: VerificationEvidence.Result) -> String {
        switch result {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .pending: "circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func evidenceColor(for result: VerificationEvidence.Result) -> Color {
        switch result {
        case .passed: Theme.success
        case .failed: Theme.danger
        case .pending: Theme.textSecondary
        case .warning: Theme.warning
        }
    }

    private func riskTone(for tier: RiskTier) -> BadgeTone {
        switch tier {
        case .low: .success
        case .medium: .warning
        case .high: .warning
        case .critical: .danger
        }
    }

    private func reviewerTone(for state: String) -> BadgeTone {
        let lower = state.lowercased()
        if lower.contains("approv") { return .success }
        if lower.contains("progress") || lower.contains("review") { return .info }
        return .neutral
    }

    /// "Step 4 of 11 — Implement", derived from the timeline when the backend
    /// sent no step position (live providers send none).
    private func stepHeadline(for detail: RunDetail) -> String {
        let summary = detail.summary
        if let text = summary.stepText {
            if let name = summary.currentStepName, !name.isEmpty {
                return "\(text) — \(name)"
            }
            return text
        }
        let count = detail.steps.count
        if let active = detail.steps.firstIndex(where: { $0.state == .active }) {
            return "Step \(active + 1) of \(count) — \(detail.steps[active].name)"
        }
        if count > 0 { return "\(count) steps" }
        return "No steps yet"
    }

    /// Backend progress when sent; otherwise derived from done/total steps.
    private func progressValue(for detail: RunDetail) -> Double {
        if let p = detail.summary.progress { return p }
        let steps = detail.steps
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { $0.state == .done }.count
        return Double(done) / Double(steps.count)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Private supporting views (in-file: this leaf owns exactly one file)

// GAP-07-shaped error card (InlineErrorCard doesn't exist yet as a
// component; this follows its spec: themeCard + danger rail + icon + title +
// message + Retry). Private: not a public API type.
private struct RunDetailErrorCard: View {
    var title: String
    var message: String
    var retryTitle: String
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Theme.danger
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                Button(retryTitle, action: onRetry)
                    .themePrimaryButton()
            }
            .padding(Theme.spacingL)
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: Theme.radiusM))
        .accessibilityElement(children: .contain)
    }
}

/// Static skeleton blocks (GAP-05 SkeletonCard doesn't exist yet). No shimmer,
/// so Reduce Motion is satisfied by construction.
private struct RunDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .frame(height: 14)
                .frame(maxWidth: 120)
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .frame(height: 28)
                .frame(maxWidth: 240)
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .frame(height: 22)
                .frame(maxWidth: 100)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .fill(Theme.surface)
                    .frame(height: 120)
            }
        }
        .accessibilityLabel("Loading run details")
    }
}

// MARK: - Previews

#Preview("Run detail — loaded") {
    NavigationStack {
        if let summary = MockRunsData.summaries.first {
            RunDetailView(run: summary, data: MockRunsData(mode: .loaded))
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Run detail — load failed") {
    NavigationStack {
        if let summary = MockRunsData.summaries.first {
            RunDetailView(run: summary, data: MockRunsData(mode: .error))
        }
    }
    .preferredColorScheme(.dark)
}
