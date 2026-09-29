# WaifuClaw/Features/Home/HomeViewModel.swift

- HomeViewModel · class · L16-L110 — @Observable @MainActor final class HomeViewModel
- HomeViewModel · method · L31-L34 — init(data: any DashboardData)
- refresh · method · L38-L43 — func refresh()
- loadSections · method · L51-L64 — private func loadSections(generation: Int) async
- isCurrent · method · L67-L69 — private func isCurrent(_ generation: Int) -> Bool
- loadAgent · method · L71-L83 — private func loadAgent(generation: Int) async
- loadThreads · method · L85-L96 — private func loadThreads(generation: Int) async
- loadMemory · method · L98-L109 — private func loadMemory(generation: Int) async
- DashboardStatePreview · struct · L116-L148 — private struct DashboardStatePreview: View
- DashboardStatePreview · method · L122-L126 — init(mode: MockDashboardData.Mode, title: String)
