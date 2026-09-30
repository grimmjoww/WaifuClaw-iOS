import Foundation

/// The result of one normal-lifecycle automatic-candidate pass. It reports
/// local queue activity only; it never represents a graph-memory write.
public struct NativeMemoryAutomaticCaptureResult: Sendable, Hashable {
    public let projectID: String
    public let runID: UUID
    public let conversationID: UUID
    public let outcome: NativeMemoryAutomaticCaptureOutcome
    public let candidateIDs: [String]
    public let evaluation: NativeMemoryAutocaptureEvaluation?

    public init(
        projectID: String,
        runID: UUID,
        conversationID: UUID,
        outcome: NativeMemoryAutomaticCaptureOutcome,
        candidateIDs: [String],
        evaluation: NativeMemoryAutocaptureEvaluation?
    ) {
        self.projectID = projectID
        self.runID = runID
        self.conversationID = conversationID
        self.outcome = outcome
        self.candidateIDs = candidateIDs
        self.evaluation = evaluation
    }
}

/// Queue-only lifecycle result. `enqueued` and `alreadyQueued` both refer to
/// unverified review candidates, never approved graph facts.
public enum NativeMemoryAutomaticCaptureOutcome: Sendable, Hashable {
    case enqueued
    case alreadyQueued
    case skipped(reason: NativeMemoryAutocaptureSkipReason)
}

/// Binding failures are errors rather than opportunities to infer an assistant
/// message from nearby conversation history.
public enum NativeMemoryAutocaptureLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidProjectID
    case runNotFound(runID: UUID, conversationID: UUID)
    case ambiguousRunBinding(runID: UUID, conversationID: UUID)
    case runConversationMismatch
    case invalidRunTimestamps
    case messageConversationMismatch
    case invalidMessageOrdering
    case assistantMessageNotFound(runID: UUID)
    case ambiguousAssistantMessageBinding(runID: UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectID:
            return "A valid native project identifier is required for automatic candidate capture."
        case .runNotFound(let runID, _):
            return "The persisted run \(runID.uuidString) was not found in this conversation."
        case .ambiguousRunBinding(let runID, _):
            return "More than one persisted run matched \(runID.uuidString); no candidate was inferred."
        case .runConversationMismatch:
            return "The persisted run belongs to a different conversation."
        case .invalidRunTimestamps:
            return "The persisted run has invalid lifecycle timestamps."
        case .messageConversationMismatch:
            return "The persisted conversation contains a message with a mismatched conversation ID."
        case .invalidMessageOrdering:
            return "The persisted conversation messages are not in deterministic chronological order."
        case .assistantMessageNotFound(let runID):
            return "No terminal assistant message could be bound to finished run \(runID.uuidString)."
        case .ambiguousAssistantMessageBinding(let runID):
            return "More than one message could be bound to finished run \(runID.uuidString); no candidate was inferred."
        }
    }
}

/// A narrow adapter for invoking automatic candidate capture after a normal
/// native-agent lifecycle. It depends only on local stores and the pure local
/// extractor. In particular, it holds no provider, credential, or
/// `LocalNeuralMemoryStore` reference, so it cannot automatically save or send
/// a graph fact.
public struct NativeMemoryAutocaptureLifecycleAdapter {
    private let runStore: LocalRunStore
    private let pendingQueue: NativeMemoryPendingCandidateQueue
    private let preferenceStore: NativeMemoryAutocapturePreferenceStore
    private let extractor: NativeMemoryAutocaptureCandidateExtractor

    public init(
        runStore: LocalRunStore,
        pendingQueue: NativeMemoryPendingCandidateQueue,
        preferenceStore: NativeMemoryAutocapturePreferenceStore = NativeMemoryAutocapturePreferenceStore(),
        extractor: NativeMemoryAutocaptureCandidateExtractor = NativeMemoryAutocaptureCandidateExtractor()
    ) {
        self.runStore = runStore
        self.pendingQueue = pendingQueue
        self.preferenceStore = preferenceStore
        self.extractor = extractor
    }

    /// Re-reads a persisted run and its explicitly identified terminal
    /// assistant message before enqueueing review-only candidates. The adapter
    /// deliberately does not use a caller-supplied output string: all evidence
    /// comes from `LocalRunStore`.
    ///
    /// The run must be `.finished`, opt-in must be set for this exact project,
    /// and `assistantMessageID` must identify exactly one persisted assistant
    /// message in `[run.createdAt, run.updatedAt]`. This avoids timestamp-only
    /// message inference when several assistant messages share a clock value.
    public func captureFinishedRun(
        runID: UUID,
        projectID: String,
        conversationID: UUID,
        assistantMessageID: UUID
    ) async throws -> NativeMemoryAutomaticCaptureResult {
        guard NativeMemoryAutocapturePreferenceStore.isValidProjectID(projectID) else {
            throw NativeMemoryAutocaptureLifecycleError.invalidProjectID
        }

        let runs = try await runStore.runs(in: conversationID)
        let matchingRuns = runs.filter { $0.id == runID }
        guard matchingRuns.count == 1 else {
            if matchingRuns.isEmpty {
                throw NativeMemoryAutocaptureLifecycleError.runNotFound(
                    runID: runID,
                    conversationID: conversationID
                )
            }
            throw NativeMemoryAutocaptureLifecycleError.ambiguousRunBinding(
                runID: runID,
                conversationID: conversationID
            )
        }
        let run = matchingRuns[0]
        guard run.conversationID == conversationID else {
            throw NativeMemoryAutocaptureLifecycleError.runConversationMismatch
        }
        guard Self.isFinite(run.createdAt), Self.isFinite(run.updatedAt),
              run.createdAt <= run.updatedAt
        else {
            throw NativeMemoryAutocaptureLifecycleError.invalidRunTimestamps
        }

        guard run.phase == .finished else {
            return NativeMemoryAutomaticCaptureResult(
                projectID: projectID,
                runID: runID,
                conversationID: conversationID,
                outcome: .skipped(reason: .runWasNotFinished),
                candidateIDs: [],
                evaluation: nil
            )
        }

        let preference = preferenceStore.preference(for: projectID)
        switch preference {
        case .unset:
            return NativeMemoryAutomaticCaptureResult(
                projectID: projectID,
                runID: runID,
                conversationID: conversationID,
                outcome: .skipped(reason: .automaticCaptureNotOptedIn),
                candidateIDs: [],
                evaluation: nil
            )
        case .optedOut:
            return NativeMemoryAutomaticCaptureResult(
                projectID: projectID,
                runID: runID,
                conversationID: conversationID,
                outcome: .skipped(reason: .automaticCaptureOptedOut),
                candidateIDs: [],
                evaluation: nil
            )
        case .optedIn:
            break
        }

        let messages = try await runStore.messages(in: conversationID)
        guard messages.allSatisfy({ $0.conversationID == conversationID }) else {
            throw NativeMemoryAutocaptureLifecycleError.messageConversationMismatch
        }
        guard Self.isChronological(messages) else {
            throw NativeMemoryAutocaptureLifecycleError.invalidMessageOrdering
        }

        let matchingMessages = messages.filter { $0.id == assistantMessageID }
        guard matchingMessages.count == 1, let assistantMessage = matchingMessages.first else {
            if matchingMessages.isEmpty {
                throw NativeMemoryAutocaptureLifecycleError.assistantMessageNotFound(runID: runID)
            }
            throw NativeMemoryAutocaptureLifecycleError.ambiguousAssistantMessageBinding(runID: runID)
        }
        guard assistantMessage.role == .assistant,
              assistantMessage.conversationID == conversationID,
              assistantMessage.createdAt >= run.createdAt,
              assistantMessage.createdAt <= run.updatedAt
        else {
            throw NativeMemoryAutocaptureLifecycleError.ambiguousAssistantMessageBinding(runID: runID)
        }

        // Exclude candidates produced by this exact run from statement-level
        // deduplication. The queue then performs exact run/candidate-ID
        // idempotency, making a retry observable as `alreadyQueued`.
        let knownStatements = try await pendingQueue.records(in: projectID)
            .filter { $0.candidate.provenance.runID != runID }
            .map { $0.candidate.statement }
        let evaluation = extractor.evaluate(
            NativeMemoryAutocaptureRunInput(
                projectID: projectID,
                run: run,
                assistantMessage: assistantMessage
            ),
            preference: preference,
            knownCandidateStatements: knownStatements
        )

        guard evaluation.disposition == .proposed else {
            let reason: NativeMemoryAutocaptureSkipReason
            switch evaluation.disposition {
            case .proposed:
                // Guarded above; preserve an exhaustiveness-safe fallback.
                reason = .noEligibleStatements
            case .skipped(let skippedReason):
                reason = skippedReason
            }
            return NativeMemoryAutomaticCaptureResult(
                projectID: projectID,
                runID: runID,
                conversationID: conversationID,
                outcome: .skipped(reason: reason),
                candidateIDs: [],
                evaluation: evaluation
            )
        }

        let appendResult = try await pendingQueue.append(
            evaluation.candidates,
            projectID: projectID,
            enqueuedAt: evaluation.evaluatedAt
        )
        let outcome: NativeMemoryAutomaticCaptureOutcome = appendResult.didInsert
            ? .enqueued
            : .alreadyQueued
        return NativeMemoryAutomaticCaptureResult(
            projectID: projectID,
            runID: runID,
            conversationID: conversationID,
            outcome: outcome,
            candidateIDs: (appendResult.insertedCandidateIDs + appendResult.existingCandidateIDs).sorted(),
            evaluation: evaluation
        )
    }

    private static func isChronological(_ messages: [LocalMessage]) -> Bool {
        guard messages.count > 1 else { return true }
        for (previous, next) in zip(messages, messages.dropFirst()) {
            if previous.createdAt > next.createdAt { return false }
            if previous.createdAt == next.createdAt,
               previous.id.uuidString > next.id.uuidString {
                return false
            }
        }
        return true
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}
