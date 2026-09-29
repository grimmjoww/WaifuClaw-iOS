# WaifuClaw/Features/Runs/RunsListView.swift

- RunsFilter · enum · L33-L53 — enum RunsFilter: String, CaseIterable, Identifiable
- matches · method · L41-L52 — func matches(_ status: RunStatus) -> Bool
- RunsListViewModel · class · L60-L132 — @Observable @MainActor final class RunsListViewModel
- Phase · enum · L64-L68 — enum Phase: Equatable
- RunsListViewModel · method · L94-L96 — nonisolated init(data: any RunsData & Sendable)
- refresh · method · L100-L127 — func refresh() async
- isCurrent · method · L129-L131 — private func isCurrent(_ generation: Int) -> Bool
- RunsListView · struct · L138-L293 — struct RunsListView: View
- RunsListView · method · L146-L148 — init(data: any RunsData & Sendable)
- refreshNoticeBanner · method · L223-L237 — private func refreshNoticeBanner(_ notice: String) -> some View
- RunRow · struct · L300-L389 — private struct RunRow: View
- badgeTone · method · L370-L382 — private func badgeTone(for status: RunStatus) -> BadgeTone
- RunsFilterChip · struct · L396-L422 — private struct RunsFilterChip: View
- RunsErrorCard · struct · L428-L459 — private struct RunsErrorCard: View
- RunsEmptyState · struct · L467-L490 — private struct RunsEmptyState: View
- RunsSkeletonRow · struct · L497-L518 — private struct RunsSkeletonRow: View
