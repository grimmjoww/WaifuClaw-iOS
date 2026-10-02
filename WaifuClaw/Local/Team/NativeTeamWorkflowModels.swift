import Foundation

/// The fixed participants in a phone-local team workflow. The first three are
/// workers; `supervisor` only synthesizes their recorded evidence.
enum NativeTeamRole: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case explorer
    case riskReviewer
    case implementationPlanner
    case supervisor

    static let workerRoles: [NativeTeamRole] = [.explorer, .riskReviewer, .implementationPlanner]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .explorer: "Explorer"
        case .riskReviewer: "Risk Reviewer"
        case .implementationPlanner: "Implementation Planner"
        case .supervisor: "Supervisor"
        }
    }

    /// This text is deliberately fixed application policy, supplied as the
    /// engine's higher-priority role directive rather than user-controlled text.
    var fixedDirective: String {
        switch self {
        case .explorer:
            return "You are the Explorer in a bounded, read-only team workflow. Inspect only the tools offered to you and report relevant structure, existing behavior, and unknowns. Do not propose or perform edits. If no project tools are offered, say that project inspection was not authorized. Never claim a build, test, edit, or verification happened without recorded tool evidence."
        case .riskReviewer:
            return "You are the Risk Reviewer in a bounded, read-only team workflow. Identify safety, correctness, migration, privacy, and delivery risks for the user's goal. Inspect only the tools offered to you. Do not propose or perform edits. Distinguish evidence from assumptions, and never claim a build, test, edit, or verification happened without recorded tool evidence."
        case .implementationPlanner:
            return "You are the Implementation Planner in a bounded, read-only team workflow. Produce a cautious, ordered implementation plan grounded in available evidence, including prerequisites and validation that remains to be run. Do not propose or perform edits. If project tools are absent, state that limitation. Never claim a build, test, edit, or verification happened without recorded tool evidence."
        case .supervisor:
            return "You are the Supervisor for a phone-local, read-only team workflow. Synthesize only the supplied worker outputs and recorded run evidence. Name worker failures and unavailable evidence, identify contradictions or uncertainty, and separate recommendations from facts. Do not claim any build, test, edit, deployment, or verification occurred unless the supplied evidence explicitly proves it. Do not invent missing worker findings."
        }
    }
}

/// Durable lifecycle of the orchestration itself. It is intentionally separate
/// from each LocalRunStore run lifecycle.
enum NativeTeamWorkflowPhase: String, Codable, CaseIterable, Sendable, Hashable {
    case workersRunning
    case synthesizing
    case completed
    case partialFailure
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .partialFailure, .failed, .cancelled, .interrupted:
            true
        case .workersRunning, .synthesizing:
            false
        }
    }

    var displayName: String {
        switch self {
        case .workersRunning: "Workers running"
        case .synthesizing: "Supervisor synthesizing"
        case .completed: "Completed"
        case .partialFailure: "Partial — inspect evidence"
        case .failed: "No worker output available"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

/// Exact durable evidence for one worker's dedicated conversation and run.
struct NativeTeamWorkerEvidence: Codable, Identifiable, Sendable, Hashable {
    let role: NativeTeamRole
    let conversationID: UUID
    var runID: UUID?
    var runPhase: LocalRunPhase?
    var outputExcerpt: String
    var runEvidenceExcerpt: String
    var errorMessage: String?
    let projectReadAllowed: Bool

    var id: NativeTeamRole { role }

    init(
        role: NativeTeamRole,
        conversationID: UUID,
        runID: UUID? = nil,
        runPhase: LocalRunPhase? = nil,
        outputExcerpt: String = "",
        runEvidenceExcerpt: String = "",
        errorMessage: String? = nil,
        projectReadAllowed: Bool
    ) {
        self.role = role
        self.conversationID = conversationID
        self.runID = runID
        self.runPhase = runPhase
        self.outputExcerpt = NativeTeamLimits.clamp(outputExcerpt, maximum: NativeTeamLimits.outputExcerptCharacters)
        self.runEvidenceExcerpt = NativeTeamLimits.clamp(runEvidenceExcerpt, maximum: NativeTeamLimits.runEvidenceCharacters)
        self.errorMessage = errorMessage.map { NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.errorCharacters) }
        self.projectReadAllowed = projectReadAllowed
    }
}

/// Evidence for the single synthesis run. It never receives project tools.
struct NativeTeamSupervisorEvidence: Codable, Sendable, Hashable {
    let role: NativeTeamRole
    let conversationID: UUID
    var runID: UUID?
    var runPhase: LocalRunPhase?
    var outputExcerpt: String
    var runEvidenceExcerpt: String
    var errorMessage: String?

    init(
        conversationID: UUID,
        runID: UUID? = nil,
        runPhase: LocalRunPhase? = nil,
        outputExcerpt: String = "",
        runEvidenceExcerpt: String = "",
        errorMessage: String? = nil
    ) {
        role = .supervisor
        self.conversationID = conversationID
        self.runID = runID
        self.runPhase = runPhase
        self.outputExcerpt = NativeTeamLimits.clamp(outputExcerpt, maximum: NativeTeamLimits.outputExcerptCharacters)
        self.runEvidenceExcerpt = NativeTeamLimits.clamp(runEvidenceExcerpt, maximum: NativeTeamLimits.runEvidenceCharacters)
        self.errorMessage = errorMessage.map { NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.errorCharacters) }
    }
}

/// A bounded phone-local history record. It contains identifiers into
/// LocalRunStore, but never provider credentials.
struct NativeTeamWorkflowRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let userGoal: String
    let projectReadAllowed: Bool
    var phase: NativeTeamWorkflowPhase
    var workers: [NativeTeamWorkerEvidence]
    var supervisor: NativeTeamSupervisorEvidence
    var finalSynthesis: String?
    var statusNote: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userGoal: String,
        projectReadAllowed: Bool,
        phase: NativeTeamWorkflowPhase = .workersRunning,
        workers: [NativeTeamWorkerEvidence],
        supervisor: NativeTeamSupervisorEvidence,
        finalSynthesis: String? = nil,
        statusNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userGoal = NativeTeamLimits.clamp(userGoal, maximum: NativeTeamLimits.goalCharacters)
        self.projectReadAllowed = projectReadAllowed
        self.phase = phase
        self.workers = workers
        self.supervisor = supervisor
        self.finalSynthesis = finalSynthesis.map {
            NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.outputExcerptCharacters)
        }
        self.statusNote = statusNote.map {
            NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.statusCharacters)
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var hasAnySuccessfulWorker: Bool {
        workers.contains { $0.runPhase == .finished && !$0.outputExcerpt.isEmpty }
    }
}

enum NativeTeamWorkflowError: LocalizedError, Sendable {
    case emptyGoal
    case goalTooLong
    case projectPermissionRequired
    case unavailableWorkflow(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "Enter a goal before starting the team workflow."
        case .goalTooLong:
            return "Keep the team goal to \(NativeTeamLimits.goalCharacters) characters or fewer."
        case .projectPermissionRequired:
            return "Choose a Files project or turn off project reading before starting this Team workflow."
        case .unavailableWorkflow:
            return "This local team workflow could not be found."
        }
    }
}

enum NativeTeamLimits {
    static let goalCharacters = 1_200
    static let outputExcerptCharacters = 8_000
    static let runEvidenceCharacters = 1_200
    static let errorCharacters = 600
    static let statusCharacters = 600
    static let supervisorPromptCharacters = 3_800
    static let historyCount = 30

    static func clamp(_ text: String, maximum: Int) -> String {
        guard text.count > maximum else { return text }
        return String(text.prefix(maximum))
    }
}
