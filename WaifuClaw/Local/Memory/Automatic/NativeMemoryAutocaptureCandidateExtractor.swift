import Foundation

/// Pure, deterministic local policy for proposing memory candidates from an
/// already persisted native run. It has no network client, no model invocation,
/// no store reference, and no memory-write API.
public struct NativeMemoryAutocaptureCandidateExtractor: Sendable {
    private static let maximumAuditRejections = 24
    private let configuration: NativeMemoryAutocaptureConfiguration

    public init(configuration: NativeMemoryAutocaptureConfiguration = NativeMemoryAutocaptureConfiguration()) {
        self.configuration = Self.normalized(configuration)
    }

    /// Evaluates exactly one locally persisted assistant message.
    ///
    /// - Parameters:
    ///   - input: Durable run and assistant-message evidence supplied by the
    ///     local lifecycle adapter after it re-reads the terminal run phase.
    ///   - preference: The independently stored per-project candidate preference.
    ///   - knownCandidateStatements: Normalized only in memory for exact-text
    ///     deduplication. Callers can supply prior proposed or approved text;
    ///     this function neither reads nor persists it.
    ///   - evaluatedAt: Injectable for reproducible tests and audit timestamps.
    /// - Returns: Candidate proposals for later review, or an audit-ready reason
    ///   why nothing was proposed. It never saves a memory.
    public func evaluate(
        _ input: NativeMemoryAutocaptureRunInput,
        preference: NativeMemoryAutocapturePreference,
        knownCandidateStatements: [String] = [],
        evaluatedAt: Date = Date()
    ) -> NativeMemoryAutocaptureEvaluation {
        func skipped(_ reason: NativeMemoryAutocaptureSkipReason) -> NativeMemoryAutocaptureEvaluation {
            NativeMemoryAutocaptureEvaluation(
                projectID: input.projectID,
                runID: input.run.id,
                assistantMessageID: input.assistantMessage.id,
                observedRunPhase: input.run.phase,
                preference: preference,
                evaluatedAt: evaluatedAt,
                disposition: .skipped(reason: reason),
                candidates: [],
                candidateRejections: []
            )
        }

        guard NativeMemoryAutocapturePreferenceStore.isValidProjectID(input.projectID) else {
            return skipped(.invalidProjectID)
        }
        switch preference {
        case .unset:
            return skipped(.automaticCaptureNotOptedIn)
        case .optedOut:
            return skipped(.automaticCaptureOptedOut)
        case .optedIn:
            break
        }
        guard input.run.phase == .finished else { return skipped(.runWasNotFinished) }
        guard input.assistantMessage.role == .assistant else { return skipped(.assistantMessageWasNotAssistant) }
        guard input.assistantMessage.conversationID == input.run.conversationID else {
            return skipped(.assistantMessageWasNotInRunConversation)
        }

        let output = input.assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return skipped(.emptyAssistantOutput) }
        guard output.count <= configuration.maximumAssistantOutputCharacters else {
            return skipped(.assistantOutputExceededLimit)
        }
        // Reject rather than redact. A candidate might otherwise retain a nearby
        // credential or misrepresent a partially redacted instruction as a fact.
        guard !Self.containsSecretLookingContent(output) else {
            return skipped(.secretLookingContent)
        }

        var normalizedKnown = Set(knownCandidateStatements.map(Self.normalizedStatement))
        normalizedKnown.remove("")
        var candidates: [NativeMemoryAutocaptureCandidate] = []
        var rejections: [NativeMemoryAutocaptureCandidateRejection] = []
        func recordRejection(_ reason: NativeMemoryAutocaptureCandidateRejection) {
            guard rejections.count < Self.maximumAuditRejections else { return }
            rejections.append(reason)
        }

        for fragment in Self.statementFragments(in: output) {
            let statement = Self.cleanStatement(fragment)
            guard !statement.isEmpty else { continue }
            guard !Self.isUnsafeFormat(statement) else {
                recordRejection(.unsafeFormat)
                continue
            }
            guard statement.count <= configuration.maximumCandidateCharacters else {
                recordRejection(.candidateTooLong)
                continue
            }
            guard Self.isHighSignalStatement(statement, minimumWords: configuration.minimumSignalWords) else {
                recordRejection(.lowSignal)
                continue
            }

            let normalized = Self.normalizedStatement(statement)
            guard !normalized.isEmpty else {
                recordRejection(.lowSignal)
                continue
            }
            guard !normalizedKnown.contains(normalized) else {
                recordRejection(.duplicate)
                continue
            }
            guard candidates.count < configuration.maximumCandidatesPerRun else {
                recordRejection(.candidateLimitReached)
                continue
            }

            let ordinal = candidates.count + 1
            let provenance = NativeMemoryAutocaptureProvenance(
                source: .finishedNativeAgentRun,
                projectID: input.projectID,
                runID: input.run.id,
                conversationID: input.run.conversationID,
                assistantMessageID: input.assistantMessage.id,
                terminalPhase: input.run.phase,
                completedAt: input.run.updatedAt
            )
            candidates.append(NativeMemoryAutocaptureCandidate(
                id: "\(input.run.id.uuidString.lowercased()):\(ordinal)",
                statement: statement,
                verification: .unverifiedModelStatement,
                provenance: provenance
            ))
            normalizedKnown.insert(normalized)
        }

        if candidates.isEmpty {
            return NativeMemoryAutocaptureEvaluation(
                projectID: input.projectID,
                runID: input.run.id,
                assistantMessageID: input.assistantMessage.id,
                observedRunPhase: input.run.phase,
                preference: preference,
                evaluatedAt: evaluatedAt,
                disposition: .skipped(reason: .noEligibleStatements),
                candidates: [],
                candidateRejections: rejections
            )
        }
        return NativeMemoryAutocaptureEvaluation(
            projectID: input.projectID,
            runID: input.run.id,
            assistantMessageID: input.assistantMessage.id,
            observedRunPhase: input.run.phase,
            preference: preference,
            evaluatedAt: evaluatedAt,
            disposition: .proposed,
            candidates: candidates,
            candidateRejections: rejections
        )
    }

    private static func normalized(_ configuration: NativeMemoryAutocaptureConfiguration) -> NativeMemoryAutocaptureConfiguration {
        NativeMemoryAutocaptureConfiguration(
            maximumAssistantOutputCharacters: min(max(configuration.maximumAssistantOutputCharacters, 512), 20_000),
            maximumCandidatesPerRun: min(max(configuration.maximumCandidatesPerRun, 1), 10),
            maximumCandidateCharacters: min(max(configuration.maximumCandidateCharacters, 80), 1_000),
            minimumSignalWords: min(max(configuration.minimumSignalWords, 3), 16)
        )
    }

    private static func statementFragments(in output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.split(whereSeparator: { ".!?".contains($0) }).map(String.init)
            }
    }

    private static func cleanStatement(_ raw: String) -> String {
        var statement = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        statement = statement.trimmingCharacters(in: CharacterSet(charactersIn: "-*•#> \t\"'"))
        for prefix in ["decision:", "summary:", "result:", "memory:", "note:"] {
            if statement.lowercased().hasPrefix(prefix) {
                statement = String(statement.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return statement
    }

    private static func isUnsafeFormat(_ statement: String) -> Bool {
        let lowercased = statement.lowercased()
        return statement.contains("```")
            || lowercased.contains("<script")
            || lowercased.hasPrefix("{\"")
            || lowercased.hasPrefix("[{")
    }

    private static func isHighSignalStatement(_ statement: String, minimumWords: Int) -> Bool {
        let words = statement.split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 1 }
        guard words.count >= minimumWords else { return false }

        let lowercased = statement.lowercased()
        let signals = [
            "decided", "decision", "choose", "chosen", "use ", "uses ",
            "using ", "configured", "prefer", "preference", "always ",
            "never ", "must ", "should ", "need to", "implemented",
            "fixed", "added", "removed", "changed", "created"
        ]
        return signals.contains { lowercased.contains($0) }
    }

    private static func normalizedStatement(_ statement: String) -> String {
        let scalars = statement.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsSecretLookingContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return secretExpressions.contains { expression in
            expression.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static let secretExpressions: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)\b(?:api[_-]?key|secret|token|password|passwd|authorization)\s*[:=]\s*["']?[A-Za-z0-9_./+=-]{8,}"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)\b(?:sk|rk|pk|ghp|github_pat|AIza)[A-Za-z0-9_-]{12,}\b"#
        ),
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        try! NSRegularExpression(pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{12,}\b"#),
        try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#)
    ]
}
