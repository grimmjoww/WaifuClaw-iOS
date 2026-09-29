import Foundation

// MARK: - Mock runs data (leaf 1.3.1)
//
// `MockRunsData` feeds previews and offline development. `mode` drives every
// call, so previews can show the loaded, empty, offline, unpaired, and error
// states — the loud-failure states the contract requires (no silent blanks,
// no spinners-forever).

struct MockRunsData: RunsData {
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

    // MARK: - RunsData

    func runs(forThread threadID: String) async throws -> [RunSummary] {
        switch mode {
        case .loaded:
            MockRunsData.summaries
        case .empty:
            []
        case .offline:
            throw RunsError.offline
        case .unpaired:
            throw RunsError.notPaired
        case .error:
            throw RunsError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func recentRuns(limit: Int) async throws -> [RunSummary] {
        Array(try await runs(forThread: "mock-thread").prefix(limit))
    }

    func runDetail(threadID: String, runID: String) async throws -> RunDetail {
        switch mode {
        case .loaded:
            guard let summary = MockRunsData.summaries.first(where: { $0.id == runID })
                ?? MockRunsData.summaries.first
            else {
                throw RunsError.server(message: "Run not found.")
            }
            return MockRunsData.detail(for: summary)
        case .empty:
            throw RunsError.server(message: "Run not found.")
        case .offline:
            throw RunsError.offline
        case .unpaired:
            throw RunsError.notPaired
        case .error:
            throw RunsError.server(message: "The desktop returned an error (HTTP 500).")
        }
    }

    func runSteps(threadID: String, runID: String) async throws -> [RunStep] {
        try await runDetail(threadID: threadID, runID: runID).steps
    }

    func cancelRun(threadID: String, runID: String, rollback: Bool) async throws {
        switch mode {
        case .loaded:
            // Mock accepts the cancel; the view model re-fetches and the
            // run's status flips in the next mock snapshot.
            return
        case .empty:
            throw RunsError.server(message: "Nothing to cancel.")
        case .offline:
            throw RunsError.offline
        case .unpaired:
            throw RunsError.notPaired
        case .error:
            throw RunsError.server(message: "The desktop returned an error (HTTP 409).")
        }
    }

    // MARK: - Fixture data

    /// Three runs covering the contract's filter chips: running, frozen
    /// (interrupted), failed. Mirror of mockup 2's OutcomeRun.
    static let summaries: [RunSummary] = {
        let now = Date.now
        return [
            RunSummary(
                id: "OR-2026-05-21-01",
                threadID: "thread_abc123",
                objective: "Implement canary deploy for the payment worker",
                status: .running,
                riskTier: .medium,
                progress: 0.36,
                stepIndex: 4,
                stepTotal: 11,
                currentStepName: "Implement",
                model: "claude-opus-4-6",
                startedAt: now.addingTimeInterval(-3_600),
                updatedAt: now.addingTimeInterval(-120),
                messageCount: 42,
                totalTokens: 18_204
            ),
            RunSummary(
                id: "OR-2026-05-21-02",
                threadID: "thread_def456",
                objective: "Migrate session store to the new schema",
                status: .interrupted,
                riskTier: .low,
                progress: 0.55,
                stepIndex: 6,
                stepTotal: 11,
                currentStepName: "Verify",
                model: "claude-opus-4-6",
                startedAt: now.addingTimeInterval(-7_200),
                updatedAt: now.addingTimeInterval(-1_800),
                messageCount: 31,
                totalTokens: 11_940
            ),
            RunSummary(
                id: "OR-2026-05-20-03",
                threadID: "thread_ghi789",
                objective: "Nightly dependency audit",
                status: .error,
                riskTier: .high,
                progress: 0.18,
                stepIndex: 2,
                stepTotal: 11,
                currentStepName: "Scan",
                model: "claude-sonnet-4-5",
                startedAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-80_000),
                messageCount: 9,
                totalTokens: 3_318
            ),
        ]
    }()

    static func detail(for summary: RunSummary) -> RunDetail {
        let steps = (0..<(summary.stepTotal ?? 11)).map { index -> RunStep in
            let oneBased = index + 1
            let state: RunStep.State
            if let current = summary.stepIndex {
                if oneBased < current {
                    state = .done
                } else if oneBased == current {
                    state = summary.status == .error ? .failed : .active
                } else {
                    state = .pending
                }
            } else {
                state = .pending
            }
            return RunStep(
                id: "\(summary.id)-\(index)",
                index: index,
                name: stepName(for: oneBased),
                state: state,
                startedAt: nil,
                endedAt: state == .done ? Date.now : nil
            )
        }
        return RunDetail(
            summary: summary,
            steps: steps,
            evidence: [
                VerificationEvidence(
                    id: "ev-pytest", name: "Pytest Suite",
                    result: .passed, detail: "926 passed"
                ),
                VerificationEvidence(
                    id: "ev-secscan", name: "Security Scan",
                    result: .passed, detail: "Clean"
                ),
                VerificationEvidence(
                    id: "ev-replay", name: "Policy Replay",
                    result: summary.status == .error ? .failed : .passed,
                    detail: summary.status == .error ? "2 violations" : "Passed"
                ),
                VerificationEvidence(
                    id: "ev-e2e", name: "E2E Replay",
                    result: .pending, detail: "Queued"
                ),
            ],
            frozenCandidate: FrozenCandidate(
                hash: "a3f9c1d2e4b5",
                frozenAt: Date.now.addingTimeInterval(-900),
                approvals: 0,
                approvalsRequired: 2,
                reviewState: "Under Review"
            ),
            riskBullets: ["Self-Improving Code", "Canary Deployment", "Rollback Ready"],
            reviewers: [
                ReviewerResult(
                    id: "rev-1", reviewerName: "Reviewer 1",
                    state: "In Progress", note: nil
                ),
                ReviewerResult(
                    id: "rev-2", reviewerName: "Reviewer 2",
                    state: "Pending", note: nil
                ),
            ]
        )
    }

    private static func stepName(for oneBased: Int) -> String {
        switch oneBased {
        case 1: "Plan"
        case 2: "Scan"
        case 3: "Draft"
        case 4: "Implement"
        case 5: "Test"
        case 6: "Verify"
        case 7: "Review"
        case 8: "Freeze"
        case 9: "Canary"
        case 10: "Promote"
        case 11: "Done"
        default: "Step \(oneBased)"
        }
    }
}
