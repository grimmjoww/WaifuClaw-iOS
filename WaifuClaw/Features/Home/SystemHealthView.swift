import SwiftUI

// MARK: - SystemHealthView
//
// Home "System Health" section (REDESIGN-CONTRACT.md §3.7): backend
// reachability, pairing state, and license service state at a glance.
// Every row is backed by a real endpoint or local pairing state — never
// invented data. Unpaired means honest `.neutral` rows; a failed fetch
// becomes a loud `.danger` row with the real error words.
//
// Deviation note: several cohesive types live in this one file (row, data
// providers, view model, private subviews) because leaf 1.2.3 owns exactly
// this file. Theme.swift sets the same precedent for a deliberate namespace.

/// Home "System Health" section: backend, pairing, and license rows with
/// independent loading, loud errors, and a working Retry.
struct SystemHealthView: View {
    @State private var viewModel: SystemHealthViewModel
    private let onPairTapped: (() -> Void)?

    /// - Parameter data: health-signal provider (live or mock).
    /// - Parameter onPairTapped: invoked by the "Pair this phone" button, which
    ///   is shown only while unpaired. Nil hides the button — never a dead control.
    init(data: any SystemHealthData, onPairTapped: (() -> Void)? = nil) {
        _viewModel = State(initialValue: SystemHealthViewModel(data: data))
        self.onPairTapped = onPairTapped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            SectionHeader(
                title: "System Health",
                actionTitle: viewModel.showsRetry ? "Retry" : nil,
                onAction: { Task { await viewModel.refresh() } }
            )
            .accessibilityAddTraits(.isHeader)

            switch viewModel.phase {
            case .loading:
                VStack(spacing: Theme.spacingS) {
                    HealthSkeletonRow()
                    HealthSkeletonRow()
                    HealthSkeletonRow()
                }
                .transition(.opacity)
                .accessibilityLabel("Checking system health")
            case .loaded(let rows):
                if rows.allSatisfy({ $0.tone == .danger }) {
                    // Every signal failed: loud error card, not three dead rows.
                    HealthErrorCard(
                        detail: rows.first?.detail,
                        onRetry: { Task { await viewModel.refresh() } }
                    )
                    .transition(.opacity)
                } else {
                    VStack(spacing: Theme.spacingXS) {
                        ForEach(rows) { HealthRowView(row: $0) }
                    }
                    .transition(.opacity)

                    if viewModel.showsPairCTA, let onPairTapped {
                        Button("Pair this phone", action: onPairTapped)
                            .themePrimaryButton()
                            .padding(.top, Theme.spacingS)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.phase)
        .task {
            await viewModel.refresh()
        }
    }
}

// MARK: - Row model

/// One health signal. The provider computes badge text and tone — the view
/// never guesses status.
struct SystemHealthRow: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case backend
        case pairing
        case license
    }

    let kind: Kind
    let title: String
    let detail: String
    let badgeText: String
    let tone: BadgeTone
    /// Tier 2 SF Symbol until the bespoke §11 icon set lands.
    let iconName: String

    var id: Kind { kind }
}

// MARK: - Data providers

/// Source of health rows. Implementations must never invent data: unpaired
/// means unknown rows, failed fetches mean down rows with real error words.
///
/// `fetchRows` never throws — a failed signal is a `.danger` row, which keeps
/// one bad endpoint from blanking the whole section.
protocol SystemHealthData {
    func fetchRows() async -> [SystemHealthRow]
}

/// Live provider: `agent/status` + `license/status` (both real endpoints in
/// `Endpoints.Remote`) plus local pairing state. Pairing reads the phone's own
/// `PairedComputer` — the authoritative "is this phone paired" signal — rather
/// than re-asking the server.
@MainActor
struct LiveSystemHealthData: SystemHealthData {
    private let api: APIClient?
    private let pairedComputer: PairedComputer?

    /// - Parameter api: nil when the phone isn't paired — rows then show the
    ///   honest unpaired state instead of attempting network calls.
    init(api: APIClient?, pairedComputer: PairedComputer?) {
        self.api = api
        self.pairedComputer = pairedComputer
    }

    /// The honest unpaired state: no signal exists, so nothing is guessed.
    static var unpairedRows: [SystemHealthRow] {
        [
            SystemHealthRow(
                kind: .backend, title: "Backend",
                detail: "Not connected",
                badgeText: "Unknown", tone: .neutral, iconName: "server.rack"
            ),
            SystemHealthRow(
                kind: .pairing, title: "Pairing",
                detail: "This phone isn't paired yet",
                badgeText: "Not paired", tone: .neutral, iconName: "link"
            ),
            SystemHealthRow(
                kind: .license, title: "License",
                detail: "Not connected",
                badgeText: "Unknown", tone: .neutral, iconName: "key.fill"
            ),
        ]
    }

    func fetchRows() async -> [SystemHealthRow] {
        guard let api else { return Self.unpairedRows }
        // Fixed fan-out of independent fetches: async let is the right shape.
        // Each row maps its own errors, so one row's failure never blanks the others.
        async let backend = backendRow(api: api)
        async let license = licenseRow(api: api)
        let pairing = pairingRow()
        return await [backend, pairing, license]
    }

    private func backendRow(api: APIClient) async -> SystemHealthRow {
        do {
            let status: AgentStatusDTO = try await api.get(Endpoints.Remote.agentStatus)
            let runs = status.runsActive
            let modelSuffix = status.model.map { " · \($0)" } ?? ""
            if runs > 0 {
                return SystemHealthRow(
                    kind: .backend, title: "Backend",
                    detail: "\(runs) run\(runs == 1 ? "" : "s") active\(modelSuffix)",
                    badgeText: "Active", tone: .success, iconName: "server.rack"
                )
            }
            return SystemHealthRow(
                kind: .backend, title: "Backend",
                detail: status.model ?? "Responding normally",
                badgeText: "Healthy", tone: .success, iconName: "server.rack"
            )
        } catch is CancellationError {
            // Never mapped to a UI error: the view model discards cancelled
            // results before they can paint.
            return unknownRow(kind: .backend, title: "Backend", iconName: "server.rack")
        } catch {
            return SystemHealthRow(
                kind: .backend, title: "Backend",
                detail: plainWords(error),
                badgeText: "Down", tone: .danger, iconName: "server.rack"
            )
        }
    }

    private func pairingRow() -> SystemHealthRow {
        if let computer = pairedComputer {
            return SystemHealthRow(
                kind: .pairing, title: "Pairing",
                detail: computer.displayName,
                badgeText: "Connected", tone: .success, iconName: "link"
            )
        }
        return SystemHealthRow(
            kind: .pairing, title: "Pairing",
            detail: "This phone isn't paired yet",
            badgeText: "Not paired", tone: .neutral, iconName: "link"
        )
    }

    private func licenseRow(api: APIClient) async -> SystemHealthRow {
        do {
            let license: LicenseStatus = try await api.get(Endpoints.Remote.licenseStatus)
            if license.isPro {
                return SystemHealthRow(
                    kind: .license, title: "License",
                    detail: proDetail(license),
                    badgeText: "Pro", tone: .success, iconName: "key.fill"
                )
            }
            return SystemHealthRow(
                kind: .license, title: "License",
                detail: "Free tier",
                badgeText: "Free", tone: .info, iconName: "key.fill"
            )
        } catch is CancellationError {
            return unknownRow(kind: .license, title: "License", iconName: "key.fill")
        } catch {
            return SystemHealthRow(
                kind: .license, title: "License",
                detail: plainWords(error),
                badgeText: "Down", tone: .danger, iconName: "key.fill"
            )
        }
    }

    private func proDetail(_ license: LicenseStatus) -> String {
        guard let days = license.daysUntilExpiry else { return "Pro" }
        if days < 0 { return "Pro · expired" }
        if days == 0 { return "Pro · expires today" }
        return "Pro · \(days) days left"
    }

    private func unknownRow(kind: SystemHealthRow.Kind, title: String, iconName: String) -> SystemHealthRow {
        SystemHealthRow(
            kind: kind, title: title,
            detail: "Checking…",
            badgeText: "Unknown", tone: .neutral, iconName: iconName
        )
    }

    private func plainWords(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Tolerant decode of the backend's agent status. The shared `AgentStatus`
/// model expects `active_runs` as an integer, but the backend also sends
/// `active_count` (and may send `active_runs` as an array) — see
/// CONTRACT_DRIFT.md. This DTO reads the integer shape when present and falls
/// back to `active_count`, so a healthy backend never shows a false "Down".
private struct AgentStatusDTO: Decodable {
    let active_count: Int?
    let queue_depth: Int?
    let model: String?
    let runsActive: Int

    private enum CodingKeys: String, CodingKey {
        case active_runs
        case active_count
        case queue_depth
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // try? (not decodeIfPresent): an array value must fall through to nil,
        // not throw a type mismatch.
        let runsAsInt = try? container.decode(Int.self, forKey: .active_runs)
        active_count = try container.decodeIfPresent(Int.self, forKey: .active_count)
        queue_depth = try container.decodeIfPresent(Int.self, forKey: .queue_depth)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        runsActive = runsAsInt ?? active_count ?? 0
    }
}

/// Canned rows for previews. `.slow` stays in the loading state so the
/// skeleton can be inspected.
struct MockSystemHealthData: SystemHealthData {
    enum Mode {
        case loaded
        case allDown
        case unpaired
        case slow
    }

    let mode: Mode

    init(mode: Mode = .loaded) {
        self.mode = mode
    }

    func fetchRows() async -> [SystemHealthRow] {
        switch mode {
        case .slow:
            try? await Task.sleep(for: .seconds(30))
            return Self.loadedRows
        case .loaded:
            return Self.loadedRows
        case .allDown:
            return Self.downRows
        case .unpaired:
            return LiveSystemHealthData.unpairedRows
        }
    }

    static var loadedRows: [SystemHealthRow] {
        [
            SystemHealthRow(
                kind: .backend, title: "Backend",
                detail: "2 runs active · waifu-1",
                badgeText: "Active", tone: .success, iconName: "server.rack"
            ),
            SystemHealthRow(
                kind: .pairing, title: "Pairing",
                detail: "Willie's ROG · 192.168.1.20",
                badgeText: "Connected", tone: .success, iconName: "link"
            ),
            SystemHealthRow(
                kind: .license, title: "License",
                detail: "Free tier",
                badgeText: "Free", tone: .info, iconName: "key.fill"
            ),
        ]
    }

    static var downRows: [SystemHealthRow] {
        [
            SystemHealthRow(
                kind: .backend, title: "Backend",
                detail: "Can't reach your computer — is it awake and on the same network?",
                badgeText: "Down", tone: .danger, iconName: "server.rack"
            ),
            SystemHealthRow(
                kind: .pairing, title: "Pairing",
                detail: "Willie's ROG · 192.168.1.20",
                badgeText: "Connected", tone: .success, iconName: "link"
            ),
            SystemHealthRow(
                kind: .license, title: "License",
                detail: "Can't reach your computer — is it awake and on the same network?",
                badgeText: "Down", tone: .danger, iconName: "key.fill"
            ),
        ]
    }
}

// MARK: - View model

/// Owns the section's load state. A generation counter gives stale-write
/// protection (same pattern as HomeViewModel): only the newest refresh may
/// paint, and cancelled results are discarded before they reach the UI.
@Observable
@MainActor
final class SystemHealthViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([SystemHealthRow])
    }

    private let data: any SystemHealthData
    private(set) var phase: Phase = .loading
    private var generation = 0

    /// Nonisolated so SwiftUI views can construct this in their own
    /// nonisolated initializers (same pattern as BYOKViewModel): the init
    /// only stores the provider.
    nonisolated init(data: any SystemHealthData) {
        self.data = data
    }

    /// Structured: call from `.task` (auto-cancelled on disappear) or a
    /// user-initiated Retry. Cancellation propagates into the fetch; a
    /// cancelled load never paints.
    func refresh() async {
        generation += 1
        let current = generation
        phase = .loading
        let rows = await data.fetchRows()
        guard generation == current, !Task.isCancelled else { return }
        phase = .loaded(rows)
    }

    /// True when at least one row is down — the header then offers Retry.
    var showsRetry: Bool {
        if case .loaded(let rows) = phase {
            return rows.contains { $0.tone == .danger }
        }
        return false
    }

    /// True only in the honest unpaired state — the "Pair this phone" button
    /// may then appear (and only if the parent supplied a real action).
    var showsPairCTA: Bool {
        if case .loaded(let rows) = phase {
            return !rows.isEmpty && rows.allSatisfy { $0.tone == .neutral }
        }
        return false
    }
}

// MARK: - Private subviews

/// One status row: icon + name + detail + badge. Not tappable — status only,
/// so there is no dead button. 44pt+ via vertical padding.
private struct HealthRowView: View {
    let row: SystemHealthRow

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: row.iconName)
                .font(.title3)
                .foregroundStyle(Theme.magenta)
                .frame(width: 36, height: 36)
                .background(Theme.magenta.opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Text(row.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(row.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.spacingS)
            StatusBadge(text: row.badgeText, tone: row.tone)
        }
        .padding(.vertical, Theme.spacingS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(row.badgeText). \(row.detail)")
    }
}

/// Loading placeholder in the shape of the rows. Static blocks — no shimmer,
/// so there is nothing to disable under Reduce Motion.
private struct HealthSkeletonRow: View {
    var body: some View {
        HStack(spacing: Theme.spacingM) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surface)
                    .frame(width: 90, height: 14)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surface)
                    .frame(width: 160, height: 12)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
                .frame(width: 76, height: 26)
        }
        .padding(.vertical, Theme.spacingS)
        .accessibilityHidden(true)
    }
}

/// Loud failure card (GAP-07 InlineErrorCard spec, built locally until that
/// leaf lands): what failed, in plain words, plus a real Retry.
private struct HealthErrorCard: View {
    let detail: String?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Theme.danger
                .frame(width: 4)
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                Label {
                    Text("Couldn't reach your computer.")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: BadgeTone.danger.symbolName)
                        .foregroundStyle(Theme.danger)
                }
                .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button("Retry", action: onRetry)
                    .themePrimaryButton()
            }
            .padding(Theme.spacingL)
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: Theme.radiusM))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: Couldn't reach your computer. \(detail ?? "")")
    }
}

// MARK: - Previews

#Preview("Loaded") {
    SystemHealthView(data: MockSystemHealthData(mode: .loaded))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

#Preview("All down") {
    SystemHealthView(data: MockSystemHealthData(mode: .allDown))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

#Preview("Unpaired") {
    SystemHealthView(data: MockSystemHealthData(mode: .unpaired), onPairTapped: {})
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

#Preview("Loading") {
    SystemHealthView(data: MockSystemHealthData(mode: .slow))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
