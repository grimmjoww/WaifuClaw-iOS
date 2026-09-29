# WaifuClaw/Features/Session/SessionViewModels.swift

- SessionListViewModel · class · L8-L40 — @Observable @MainActor final class SessionListViewModel
- Phase · enum · L11-L15 — enum Phase: Equatable
- SessionListViewModel · method · L22-L24 — init(runsData: any RunsData & Sendable)
- refresh · method · L28-L39 — func refresh() async
- SessionDetailViewModel · class · L52-L216 — @Observable @MainActor final class SessionDetailViewModel
- SessionDetailViewModel · method · L74-L79 — init(summary: RunSummary, data: any SessionData & Sendable)
- start · method · L87-L91 — func start() async
- stop · method · L95-L98 — func stop()
- scrollKey · method · L102-L104 — static func scrollKey(for runID: String) -> String
- setAutoScroll · method · L106-L109 — func setAutoScroll(_ value: Bool)
- pause · method · L113-L119 — func pause()
- resume · method · L121-L123 — func resume()
- reconnect · method · L125-L127 — func reconnect()
- retrySkills · method · L129-L131 — func retrySkills() async
- loadBacklog · method · L135-L146 — private func loadBacklog() async
- loadSkills · method · L148-L159 — private func loadSkills() async
- connect · method · L166-L204 — private func connect()
- phaseForError · method · L209-L215 — private static func phaseForError(_ error: Error) -> SessionStreamPhase
