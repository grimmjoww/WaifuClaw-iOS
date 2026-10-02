import Foundation

/// The persisted choice for automatic *candidate* extraction in one selected
/// native project. It is intentionally distinct from permission to send
/// approved memories to a BYOK provider.
public enum NativeMemoryAutocapturePreference: String, Codable, Sendable, Hashable {
    /// No choice has been made. This is the default and is treated as off.
    case unset
    /// The user allows bounded local proposals from this project's finished runs.
    case optedIn
    /// The user explicitly declined automatic local proposals for this project.
    case optedOut

    public var allowsCandidateExtraction: Bool { self == .optedIn }
}

/// A source that can be shown in an audit UI without treating a model statement
/// as a verified memory fact.
public enum NativeMemoryAutocaptureSource: String, Codable, Sendable, Hashable {
    case finishedNativeAgentRun
}

/// The only truth-status available to automatic candidates in this slice.
///
/// A candidate is model output, not an established fact. A future UI may let a
/// user review it and construct a separately approved memory request; this type
/// deliberately has no conversion to a memory-store write request.
public enum NativeMemoryAutocaptureVerification: String, Codable, Sendable, Hashable {
    case unverifiedModelStatement
}

/// Durable local evidence describing where an automatic candidate came from.
/// No raw terminal output, credentials, or provider information is retained here.
public struct NativeMemoryAutocaptureProvenance: Codable, Sendable, Hashable {
    public let source: NativeMemoryAutocaptureSource
    public let projectID: String
    public let runID: UUID
    public let conversationID: UUID
    public let assistantMessageID: UUID
    public let terminalPhase: LocalRunPhase
    public let completedAt: Date

    public init(
        source: NativeMemoryAutocaptureSource,
        projectID: String,
        runID: UUID,
        conversationID: UUID,
        assistantMessageID: UUID,
        terminalPhase: LocalRunPhase,
        completedAt: Date
    ) {
        self.source = source
        self.projectID = projectID
        self.runID = runID
        self.conversationID = conversationID
        self.assistantMessageID = assistantMessageID
        self.terminalPhase = terminalPhase
        self.completedAt = completedAt
    }
}

/// A bounded local proposal extracted from a successful native agent run.
///
/// It is never a stored memory fact, always remains unverified, and requires a
/// future explicit review flow before any separate persistence action.
public struct NativeMemoryAutocaptureCandidate: Codable, Identifiable, Sendable, Hashable {
    /// Stable only within the run: `<run UUID>:<ordinal>`.
    public let id: String
    public let statement: String
    public let verification: NativeMemoryAutocaptureVerification
    public let provenance: NativeMemoryAutocaptureProvenance

    public init(
        id: String,
        statement: String,
        verification: NativeMemoryAutocaptureVerification,
        provenance: NativeMemoryAutocaptureProvenance
    ) {
        self.id = id
        self.statement = statement
        self.verification = verification
        self.provenance = provenance
    }

    /// Always true. This slice never performs memory persistence.
    public var requiresExplicitReview: Bool { true }
}

/// A reason an entire finished-run evaluation produced no reviewable proposal.
/// The surrounding evaluation retains run, phase, preference, and time for an
/// audit without retaining rejected sensitive content.
public enum NativeMemoryAutocaptureSkipReason: String, Codable, Sendable, Hashable {
    case invalidProjectID
    case automaticCaptureNotOptedIn
    case automaticCaptureOptedOut
    case runWasNotFinished
    case assistantMessageWasNotAssistant
    case assistantMessageWasNotInRunConversation
    case emptyAssistantOutput
    case assistantOutputExceededLimit
    case secretLookingContent
    case noEligibleStatements
}

/// A non-sensitive explanation for rejecting an individual text fragment.
public enum NativeMemoryAutocaptureCandidateRejection: String, Codable, Sendable, Hashable {
    case lowSignal
    case duplicate
    case candidateTooLong
    case candidateLimitReached
    case unsafeFormat
}

/// Whether this evaluation made proposals available for review or stopped.
public enum NativeMemoryAutocaptureDisposition: Codable, Sendable, Hashable {
    case proposed
    case skipped(reason: NativeMemoryAutocaptureSkipReason)
}

/// Audit-ready result of a pure, local candidate evaluation.
///
/// `candidates` are proposals only. Nothing in this result writes a memory,
/// changes a consent preference, or contacts a provider.
public struct NativeMemoryAutocaptureEvaluation: Codable, Sendable, Hashable {
    public let projectID: String
    public let runID: UUID
    public let assistantMessageID: UUID
    public let observedRunPhase: LocalRunPhase
    public let preference: NativeMemoryAutocapturePreference
    public let evaluatedAt: Date
    public let disposition: NativeMemoryAutocaptureDisposition
    public let candidates: [NativeMemoryAutocaptureCandidate]
    /// One entry per discarded non-sensitive fragment; never contains fragment text.
    public let candidateRejections: [NativeMemoryAutocaptureCandidateRejection]

    public init(
        projectID: String,
        runID: UUID,
        assistantMessageID: UUID,
        observedRunPhase: LocalRunPhase,
        preference: NativeMemoryAutocapturePreference,
        evaluatedAt: Date,
        disposition: NativeMemoryAutocaptureDisposition,
        candidates: [NativeMemoryAutocaptureCandidate],
        candidateRejections: [NativeMemoryAutocaptureCandidateRejection]
    ) {
        self.projectID = projectID
        self.runID = runID
        self.assistantMessageID = assistantMessageID
        self.observedRunPhase = observedRunPhase
        self.preference = preference
        self.evaluatedAt = evaluatedAt
        self.disposition = disposition
        self.candidates = candidates
        self.candidateRejections = candidateRejections
    }
}

/// The exact local evidence a lifecycle adapter must supply for evaluation.
///
/// The adapter must pass the assistant message committed by `run` after it has
/// re-read the run's terminal phase from `LocalRunStore`. The extractor accepts
/// only `.finished`; queued, running, failed, and cancelled runs never yield a
/// candidate.
public struct NativeMemoryAutocaptureRunInput: Sendable, Hashable {
    public let projectID: String
    public let run: LocalRunRecord
    public let assistantMessage: LocalMessage

    public init(projectID: String, run: LocalRunRecord, assistantMessage: LocalMessage) {
        self.projectID = projectID
        self.run = run
        self.assistantMessage = assistantMessage
    }
}

/// Fixed local bounds for deterministic candidate extraction.
public struct NativeMemoryAutocaptureConfiguration: Sendable, Hashable {
    public var maximumAssistantOutputCharacters: Int
    public var maximumCandidatesPerRun: Int
    public var maximumCandidateCharacters: Int
    public var minimumSignalWords: Int

    public init(
        maximumAssistantOutputCharacters: Int = 6_000,
        maximumCandidatesPerRun: Int = 3,
        maximumCandidateCharacters: Int = 280,
        minimumSignalWords: Int = 5
    ) {
        self.maximumAssistantOutputCharacters = maximumAssistantOutputCharacters
        self.maximumCandidatesPerRun = maximumCandidatesPerRun
        self.maximumCandidateCharacters = maximumCandidateCharacters
        self.minimumSignalWords = minimumSignalWords
    }
}
