# WaifuClaw/Features/Runs/MockRunsData.swift

- MockRunsData · struct · L10-L228 — struct MockRunsData: RunsData
- Mode · enum · L11-L17 — enum Mode
- MockRunsData · method · L21-L23 — init(mode: Mode = .loaded)
- runs · method · L27-L40 — func runs(forThread threadID: String) async throws -> [RunSummary]
- recentRuns · method · L42-L44 — func recentRuns(limit: Int) async throws -> [RunSummary]
- runDetail · method · L46-L64 — func runDetail(threadID: String, runID: String) async throws -> RunDetail
- runSteps · method · L66-L68 — func runSteps(threadID: String, runID: String) async throws -> [RunStep]
- cancelRun · method · L70-L85 — func cancelRun(threadID: String, runID: String, rollback: Bool) async throws
- detail · method · L145-L210 — static func detail(for summary: RunSummary) -> RunDetail
- stepName · method · L212-L227 — private static func stepName(for oneBased: Int) -> String
