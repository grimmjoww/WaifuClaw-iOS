# WaifuClaw/Features/Team/MockTeamData.swift

- MockTeamData · struct · L16-L289 — struct MockTeamData: TeamData
- Mode · enum · L17-L23 — enum Mode
- MockTeamData · method · L27-L29 — init(mode: Mode = .loaded)
- members · method · L33-L46 — func members() async throws -> [TeamMember]
- conversations · method · L48-L61 — func conversations(limit: Int) async throws -> [TeamConversation]
- messages · method · L63-L76 — func messages(threadID: String, limit: Int) async throws -> [TeamMessage]
- inboxItems · method · L78-L91 — func inboxItems(limit: Int) async throws -> [InboxItem]
- board · method · L93-L106 — func board() async throws -> TeamBoard
- taskDetail · method · L108-L124 — func taskDetail(id: String) async throws -> TeamTaskDetail
- milestones · method · L126-L139 — func milestones() async throws -> [Milestone]
- card · method · L213-L218 — func card(_ id: String, _ title: String, _ assignee: String, _ priority: TaskPriority, _ column: TaskColumn, threadID: String? = nil) -> TeamTask
