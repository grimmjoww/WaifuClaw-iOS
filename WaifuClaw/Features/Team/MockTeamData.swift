import Foundation

// MARK: - Mock team data (leaf 1.4.1)
//
// `MockTeamData` feeds previews and offline development. `mode` drives every
// call, so previews can show the loaded, empty, offline, unpaired, and error
// states — the loud-failure states the contract requires (no silent blanks,
// no spinners-forever).
//
// Fixtures are faithful to mockup 4 (kanban team board, 2026-09-28):
// six columns (3/4/5/3/4/2), the Active Agents rail
// (Rei/Sage/Kline/Hermes/Miko/Zen), Team Inbox rows, and the four milestone
// tiles. The conversations double as the conversational agent-to-agent view
// Willie leans toward — same threads back both presentations.

struct MockTeamData: TeamData {
    enum Mode {
        case loaded
        case empty
        case offline
        case unpaired
        case error
    }

    let mode: Mode

    init(mode: Mode = .loaded) {
        self.mode = mode
    }

    // MARK: - TeamData

    func members() async throws -> [TeamMember] {
        switch mode {
        case .loaded:
            MockTeamData.members
        case .empty:
            []
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func conversations(limit: Int) async throws -> [TeamConversation] {
        switch mode {
        case .loaded:
            Array(MockTeamData.conversations.prefix(limit))
        case .empty:
            []
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func messages(threadID: String, limit: Int) async throws -> [TeamMessage] {
        switch mode {
        case .loaded:
            Array((MockTeamData.messagesByThread[threadID] ?? []).prefix(limit))
        case .empty:
            []
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func inboxItems(limit: Int) async throws -> [InboxItem] {
        switch mode {
        case .loaded:
            Array(MockTeamData.inbox.prefix(limit))
        case .empty:
            []
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func board() async throws -> TeamBoard {
        switch mode {
        case .loaded:
            MockTeamData.board
        case .empty:
            .empty
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func taskDetail(id: String) async throws -> TeamTaskDetail {
        switch mode {
        case .loaded:
            guard let detail = MockTeamData.details[id] else {
                throw TeamError.server(message: "Task #\(id) not found.")
            }
            return detail
        case .empty:
            throw TeamError.server(message: "Task #\(id) not found.")
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func milestones() async throws -> [Milestone] {
        switch mode {
        case .loaded:
            MockTeamData.milestones
        case .empty:
            []
        case .offline:
            throw TeamError.offline
        case .unpaired:
            throw TeamError.notPaired
        case .error:
            throw TeamError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    // MARK: - Fixtures

    static let members: [TeamMember] = [
        TeamMember(id: "rei", displayName: "Rei", role: "Generalist Engineer",
                   model: nil, skills: nil, presence: .busy),
        TeamMember(id: "sage", displayName: "Sage", role: "Reviewer",
                   model: nil, skills: nil, presence: .busy),
        TeamMember(id: "kline", displayName: "Kline", role: "Operator & Guide",
                   model: nil, skills: nil, presence: .online),
        TeamMember(id: "hermes", displayName: "Hermes", role: "Courier · v0.9.8",
                   model: nil, skills: nil, presence: .online),
        TeamMember(id: "miko", displayName: "Miko", role: "Shrine Maiden",
                   model: nil, skills: nil, presence: .online),
        TeamMember(id: "zen", displayName: "Zen", role: "Monk",
                   model: nil, skills: nil, presence: .offline),
    ]

    static let conversations: [TeamConversation] = [
        TeamConversation(id: "thread-hermes-sage", title: "Hermes-Sage finalization",
                         status: .busy, updatedAt: Date.now.addingTimeInterval(-720),
                         createdAt: Date.now.addingTimeInterval(-86400)),
        TeamConversation(id: "thread-memory-recall", title: "Memory recall improvements",
                         status: .idle, updatedAt: Date.now.addingTimeInterval(-10800),
                         createdAt: Date.now.addingTimeInterval(-172800)),
        TeamConversation(id: "thread-policy-delta", title: "Policy replay delta",
                         status: .interrupted, updatedAt: Date.now.addingTimeInterval(-21600),
                         createdAt: Date.now.addingTimeInterval(-259200)),
    ]

    static let messagesByThread: [String: [TeamMessage]] = [
        "thread-hermes-sage": [
            TeamMessage(id: "thread-hermes-sage-1", threadID: "thread-hermes-sage",
                        role: .agent, text: "Step 4 reviews started — the frozen candidate is under review.",
                        runID: "run-01", createdAt: Date.now.addingTimeInterval(-3600), authorName: "Rei"),
            TeamMessage(id: "thread-hermes-sage-2", threadID: "thread-hermes-sage",
                        role: .agent, text: "Reviewer 1 in progress. Evidence looks real so far.",
                        runID: "run-01", createdAt: Date.now.addingTimeInterval(-1800), authorName: "Sage"),
            TeamMessage(id: "thread-hermes-sage-3", threadID: "thread-hermes-sage",
                        role: .agent, text: "Holding the freeze until both reviewers sign. No approval binds to changed bytes.",
                        runID: "run-02", createdAt: Date.now.addingTimeInterval(-720), authorName: "Rei"),
        ],
        "thread-memory-recall": [
            TeamMessage(id: "thread-memory-recall-1", threadID: "thread-memory-recall",
                        role: .agent, text: "Memory recall updated — 41.2% hit rate on last recall.",
                        runID: "run-03", createdAt: Date.now.addingTimeInterval(-10800), authorName: "Kline"),
            TeamMessage(id: "thread-memory-recall-2", threadID: "thread-memory-recall",
                        role: .agent, text: "Noted. Associative depth is next.",
                        runID: "run-03", createdAt: Date.now.addingTimeInterval(-10400), authorName: "Sage"),
        ],
        "thread-policy-delta": [
            TeamMessage(id: "thread-policy-delta-1", threadID: "thread-policy-delta",
                        role: .agent, text: "Policy replay delta is 1/2 — second pass stalled.",
                        runID: "run-04", createdAt: Date.now.addingTimeInterval(-21600), authorName: "Hermes"),
            TeamMessage(id: "thread-policy-delta-2", threadID: "thread-policy-delta",
                        role: .agent, text: "Re-running the failed half now.",
                        runID: "run-05", createdAt: Date.now.addingTimeInterval(-21000), authorName: "Rei"),
        ],
    ]

    static let inbox: [InboxItem] = [
        InboxItem(id: "thread-hermes-sage", title: "Hermes-Sage finalization",
                  snippet: "Sage: Reviewer 1 in progress. Evidence looks real so far.",
                  updatedAt: Date.now.addingTimeInterval(-720)),
        InboxItem(id: "thread-memory-recall", title: "Memory recall improvements",
                  snippet: "Rei: Tests 926 pass — suite green.",
                  updatedAt: Date.now.addingTimeInterval(-3600)),
        InboxItem(id: "thread-policy-delta", title: "Policy replay delta",
                  snippet: "Kline: Memory recall updated.",
                  updatedAt: Date.now.addingTimeInterval(-10800)),
    ]

    static let board: TeamBoard = {
        func card(_ id: String, _ title: String, _ assignee: String,
                  _ priority: TaskPriority, _ column: TaskColumn,
                  threadID: String? = nil) -> TeamTask {
            TeamTask(id: id, title: title, assignee: assignee,
                     priority: priority, column: column, threadID: threadID, progress: nil)
        }
        let columns: [BoardColumn] = [
            BoardColumn(column: .inbox, tasks: [
                card("642", "Add memory compression v2", "Rei", .medium, .inbox),
                card("645", "Design evolution engine API", "Sage", .medium, .inbox),
                card("644", "Update policy replay rules", "Sage", .high, .inbox),
            ]),
            BoardColumn(column: .planned, tasks: [
                card("649", "Native IDE tooling", "Hermes", .medium, .planned),
                card("646", "OutcomeRun desktop UI", "Kline", .medium, .planned),
                card("650", "Self-improving carly fix", "Rei", .medium, .planned),
                card("648", "Skill success analytics", "Miko", .medium, .planned),
            ]),
            BoardColumn(column: .inProgress, tasks: [
                card("653", "Hermes-Sage finalization", "Rei", .high, .inProgress,
                     threadID: "thread-hermes-sage"),
                card("651", "Worker profile refactor", "Sage", .medium, .inProgress),
                card("655", "IDE diagnostics engine", "Kline", .medium, .inProgress),
                card("656", "WaifuClaw UI", "Kline", .medium, .inProgress),
                card("657", "Policy replay delta", "Sage", .low, .inProgress,
                     threadID: "thread-policy-delta"),
            ]),
            BoardColumn(column: .review, tasks: [
                card("658", "Step 4 reviews (frozen candidate)", "Sage", .high, .review,
                     threadID: "thread-hermes-sage"),
                card("659", "Security audit", "Rei", .high, .review),
                card("660", "Tests 926 pass", "Rei", .medium, .review),
            ]),
            BoardColumn(column: .verified, tasks: [
                card("661", "Router refactor", "Hermes", .medium, .verified),
                card("662", "ACP 1.2.3", "Hermes", .low, .verified),
                card("663", "Docs update", "Kline", .low, .verified),
                card("664", "Memory recall improved", "Sage", .low, .verified,
                     threadID: "thread-memory-recall"),
            ]),
            BoardColumn(column: .deployed, tasks: [
                card("665", "Release v1.2.3", "Hermes", .low, .deployed),
                card("666", "Release v0.9.8", "Hermes", .low, .deployed),
            ]),
        ]
        return TeamBoard(columns: columns)
    }()

    static let details: [String: TeamTaskDetail] = {
        let finalization = TeamTask(
            id: "653", title: "Hermes-Sage finalization", assignee: "Rei",
            priority: .high, column: .inProgress, threadID: "thread-hermes-sage",
            progress: 0.33
        )
        return [
            "653": TeamTaskDetail(
                task: finalization,
                progress: 0.33,
                verificationsPassed: 5,
                verificationsTotal: 7,
                reviewersDone: 1,
                reviewersTotal: 2,
                branch: "feature/hermes-sage-final",
                frozenHash: "b732fc…e4f7",
                riskBadges: ["Self-Modifying"],
                outcomeStepText: "Step 4: Implement"
            ),
        ]
    }()

    static let milestones: [Milestone] = [
        Milestone(id: "m1", title: "1000 Tasks", subtitle: "Completed"),
        Milestone(id: "m2", title: "Streak 42", subtitle: "Days Active"),
        Milestone(id: "m3", title: "Self-improver", subtitle: "Unlocked"),
        Milestone(id: "m4", title: "Bug Crusher", subtitle: "100 bugs squashed"),
    ]
}
