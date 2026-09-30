import Foundation

/// A record in the local-only review queue for an automatically extracted
/// candidate. `candidate.verification` is always `.unverifiedModelStatement`;
/// queue state describes only an approval operation and never truthfulness.
public struct NativeMemoryPendingCandidateRecord: Codable, Identifiable, Sendable, Hashable {
    public let candidate: NativeMemoryAutocaptureCandidate
    public let projectID: String
    public let enqueuedAt: Date
    public let state: NativeMemoryPendingCandidateState

    /// The exact extractor candidate ID, `<run UUID lowercase>:<ordinal>`.
    public var id: String { candidate.id }

    public init(
        candidate: NativeMemoryAutocaptureCandidate,
        projectID: String,
        enqueuedAt: Date,
        state: NativeMemoryPendingCandidateState = .pending
    ) {
        self.candidate = candidate
        self.projectID = projectID
        self.enqueuedAt = enqueuedAt
        self.state = state
    }
}

/// Lifecycle state internal to the review queue. It is not a verification
/// status and must never be shown as a verified memory fact.
public enum NativeMemoryPendingCandidateState: String, Codable, Sendable, Hashable {
    case pending
    /// Persisted before an explicit user approval calls the graph store. A
    /// claimed record fails closed after an interruption rather than risking a
    /// second graph capture for the same candidate.
    case approvalClaimed
}

/// Result of an idempotent queue append. Existing IDs are exact matches whose
/// persisted candidate payload was identical to the requested payload.
public struct NativeMemoryPendingCandidateAppendResult: Sendable, Hashable {
    public let insertedCandidateIDs: [String]
    public let existingCandidateIDs: [String]

    public var didInsert: Bool { !insertedCandidateIDs.isEmpty }

    public init(insertedCandidateIDs: [String], existingCandidateIDs: [String]) {
        self.insertedCandidateIDs = insertedCandidateIDs
        self.existingCandidateIDs = existingCandidateIDs
    }
}

/// Local export payload for pending automatic candidates. This is deliberately
/// distinct from `LocalMemoryExport`: it contains no graph facts, anchors, or
/// synapses, and cannot represent a candidate as an approved fact.
public struct NativeMemoryPendingCandidateExport: Codable, Sendable, Hashable {
    public let formatVersion: Int
    public let projectID: String
    public let exportedAt: Date
    public let records: [NativeMemoryPendingCandidateRecord]

    public init(
        formatVersion: Int,
        projectID: String,
        exportedAt: Date,
        records: [NativeMemoryPendingCandidateRecord]
    ) {
        self.formatVersion = formatVersion
        self.projectID = projectID
        self.exportedAt = exportedAt
        self.records = records
    }
}

/// Bounded configuration for the local review queue. Values are normalized by
/// `NativeMemoryPendingCandidateQueue` so a caller cannot disable limits.
public struct NativeMemoryPendingCandidateQueueConfiguration: Sendable, Hashable {
    public var maximumPendingRecordsPerProject: Int
    public var maximumPendingRecordsTotal: Int
    public var maximumStatementCharacters: Int
    public var maximumDocumentBytes: Int

    public init(
        maximumPendingRecordsPerProject: Int = 100,
        maximumPendingRecordsTotal: Int = 1_000,
        maximumStatementCharacters: Int = 1_000,
        maximumDocumentBytes: Int = 2_000_000
    ) {
        self.maximumPendingRecordsPerProject = maximumPendingRecordsPerProject
        self.maximumPendingRecordsTotal = maximumPendingRecordsTotal
        self.maximumStatementCharacters = maximumStatementCharacters
        self.maximumDocumentBytes = maximumDocumentBytes
    }
}

/// Errors for the protected, local pending-candidate queue. Error descriptions
/// intentionally omit candidate text so malformed or secret-looking input is
/// never echoed into an audit log.
public enum NativeMemoryPendingCandidateQueueError: Error, Equatable, LocalizedError, Sendable {
    case invalidFileURL(String)
    case applicationSupportUnavailable
    case incompatibleFormatVersion(found: Int, supported: Int)
    case corruptData
    case invalidProjectID
    case invalidCandidate
    case duplicateCandidateIDInRequest
    case candidateIDBoundToAnotherProject
    case candidateConflict
    case queueCapacityReached(projectID: String)
    case recordNotFound(id: String, projectID: String)
    case approvalInProgress(id: String, projectID: String)
    case invalidApprovalNote

    public var errorDescription: String? {
        switch self {
        case .invalidFileURL(let value):
            return "The pending-candidate queue URL is not a file URL: \(value)"
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .incompatibleFormatVersion(let found, let supported):
            return "Pending-candidate queue format \(found) is newer than supported format \(supported)."
        case .corruptData:
            return "The local pending-candidate queue is invalid and was not used."
        case .invalidProjectID:
            return "A valid native project identifier is required."
        case .invalidCandidate:
            return "The automatic candidate does not meet local safety or provenance requirements."
        case .duplicateCandidateIDInRequest:
            return "The append request contains the same candidate ID more than once."
        case .candidateIDBoundToAnotherProject:
            return "The candidate ID is already bound to another local project."
        case .candidateConflict:
            return "The candidate ID conflicts with a different local candidate payload."
        case .queueCapacityReached(let projectID):
            return "The pending-candidate queue is at capacity for project \(projectID)."
        case .recordNotFound(let id, _):
            return "Pending candidate \(id) was not found."
        case .approvalInProgress(let id, _):
            return "Pending candidate \(id) has an interrupted or active user approval and cannot be captured again automatically."
        case .invalidApprovalNote:
            return "The user approval note is too long or appears to contain a credential."
        }
    }
}

/// Actor-isolated, versioned JSON queue for unverified automatic candidates.
///
/// The queue is device-local: it has no provider dependency, network API,
/// credential field, or graph-memory export. Writes use `Data` atomic replace
/// plus complete file protection. Corrupt or unsupported on-disk state is
/// rejected at open rather than repaired or guessed.
public actor NativeMemoryPendingCandidateQueue {
    private static let formatVersion = 1
    private static let maximumCandidatesPerAppend = 10
    private static let maximumPendingRecordsHardLimit = 5_000
    private static let maximumDocumentBytesHardLimit = 4_000_000

    private struct Document: Codable {
        let formatVersion: Int
        let updatedAt: Date
        let records: [NativeMemoryPendingCandidateRecord]
    }

    private let fileURL: URL
    private let configuration: NativeMemoryPendingCandidateQueueConfiguration
    private var document: Document

    /// Opens the queue at an explicit local file URL, or under Application
    /// Support when the host app does not supply one. The initial read fully
    /// validates the document before exposing any records.
    public init(
        fileURL: URL? = nil,
        configuration: NativeMemoryPendingCandidateQueueConfiguration = NativeMemoryPendingCandidateQueueConfiguration()
    ) throws {
        let resolvedURL = try fileURL ?? Self.defaultFileURL()
        guard resolvedURL.isFileURL else {
            throw NativeMemoryPendingCandidateQueueError.invalidFileURL(resolvedURL.absoluteString)
        }

        let normalizedConfiguration = Self.normalized(configuration)
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.fileURL = resolvedURL
        self.configuration = normalizedConfiguration
        self.document = try Self.loadDocument(at: resolvedURL, configuration: normalizedConfiguration)
    }

    /// Returns all queue records for a project, including a durable in-progress
    /// user-approval claim. Callers normally use `pendingRecords(in:)` for a
    /// review UI; this broader method supports exact-text deduplication.
    public func records(in projectID: String) throws -> [NativeMemoryPendingCandidateRecord] {
        try Self.validateProjectID(projectID)
        return ordered(document.records.filter { $0.projectID == projectID })
    }

    /// Returns only reviewable pending records for one project. A claimed
    /// record is never automatically retried after an interruption.
    public func pendingRecords(in projectID: String) throws -> [NativeMemoryPendingCandidateRecord] {
        try Self.validateProjectID(projectID)
        return ordered(document.records.filter {
            $0.projectID == projectID && $0.state == .pending
        })
    }

    /// Appends candidates atomically. Candidate IDs are globally unique within
    /// the queue and are idempotent only when the full persisted payload is
    /// identical. No candidate is transformed, verified, or sent anywhere.
    @discardableResult
    public func append(
        _ candidates: [NativeMemoryAutocaptureCandidate],
        projectID: String,
        enqueuedAt: Date = Date()
    ) throws -> NativeMemoryPendingCandidateAppendResult {
        try Self.validateProjectID(projectID)
        guard !candidates.isEmpty, candidates.count <= Self.maximumCandidatesPerAppend,
              Self.isFinite(enqueuedAt)
        else {
            throw NativeMemoryPendingCandidateQueueError.invalidCandidate
        }

        var requestedIDs = Set<String>()
        for candidate in candidates {
            guard requestedIDs.insert(candidate.id).inserted else {
                throw NativeMemoryPendingCandidateQueueError.duplicateCandidateIDInRequest
            }
            try Self.validate(candidate, projectID: projectID, maximumStatementCharacters: configuration.maximumStatementCharacters)
        }

        var inserted: [String] = []
        var existing: [String] = []
        var newRecords: [NativeMemoryPendingCandidateRecord] = []
        for candidate in candidates {
            let matchingRecords = document.records.filter { $0.id == candidate.id }
            if let persisted = matchingRecords.first {
                guard persisted.projectID == projectID else {
                    throw NativeMemoryPendingCandidateQueueError.candidateIDBoundToAnotherProject
                }
                guard matchingRecords.count == 1, persisted.candidate == candidate else {
                    throw NativeMemoryPendingCandidateQueueError.candidateConflict
                }
                existing.append(candidate.id)
            } else {
                inserted.append(candidate.id)
                newRecords.append(NativeMemoryPendingCandidateRecord(
                    candidate: candidate,
                    projectID: projectID,
                    enqueuedAt: enqueuedAt
                ))
            }
        }

        guard !newRecords.isEmpty else {
            return NativeMemoryPendingCandidateAppendResult(
                insertedCandidateIDs: [],
                existingCandidateIDs: existing.sorted()
            )
        }

        let projectCount = document.records.filter { $0.projectID == projectID }.count
        guard projectCount + newRecords.count <= configuration.maximumPendingRecordsPerProject,
              document.records.count + newRecords.count <= configuration.maximumPendingRecordsTotal
        else {
            throw NativeMemoryPendingCandidateQueueError.queueCapacityReached(projectID: projectID)
        }

        try replaceDocument(records: document.records + newRecords)
        return NativeMemoryPendingCandidateAppendResult(
            insertedCandidateIDs: inserted.sorted(),
            existingCandidateIDs: existing.sorted()
        )
    }

    /// Deletes exactly one still-pending candidate. Deletion is local and does
    /// not affect graph memories because pending candidates are not graph facts.
    @discardableResult
    public func deletePendingCandidate(
        id: String,
        projectID: String
    ) throws -> NativeMemoryPendingCandidateRecord {
        try Self.validateProjectID(projectID)
        guard let index = document.records.firstIndex(where: {
            $0.id == id && $0.projectID == projectID
        }) else {
            throw NativeMemoryPendingCandidateQueueError.recordNotFound(id: id, projectID: projectID)
        }
        let record = document.records[index]
        guard record.state == .pending else {
            throw NativeMemoryPendingCandidateQueueError.approvalInProgress(id: id, projectID: projectID)
        }

        var records = document.records
        records.remove(at: index)
        try replaceDocument(records: records)
        return record
    }

    /// Deletes all reviewable pending records in one project and returns the
    /// number removed. Interrupted approval claims are retained fail-closed.
    @discardableResult
    public func deleteAllPending(in projectID: String) throws -> Int {
        try Self.validateProjectID(projectID)
        let removedCount = document.records.filter {
            $0.projectID == projectID && $0.state == .pending
        }.count
        guard removedCount > 0 else { return 0 }

        try replaceDocument(records: document.records.filter {
            !($0.projectID == projectID && $0.state == .pending)
        })
        return removedCount
    }

    /// Exports one project's pending review records only. Approved graph facts
    /// are neither queried nor represented by this payload.
    public func exportProject(
        _ projectID: String,
        exportedAt: Date = Date()
    ) throws -> NativeMemoryPendingCandidateExport {
        try Self.validateProjectID(projectID)
        guard Self.isFinite(exportedAt) else {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }
        return NativeMemoryPendingCandidateExport(
            formatVersion: Self.formatVersion,
            projectID: projectID,
            exportedAt: exportedAt,
            records: try pendingRecords(in: projectID)
        )
    }

    /// Produces deterministic-key-order local JSON for user-directed pending
    /// candidate export. It is intentionally not a graph-memory export.
    public func exportJSON(
        forProject projectID: String,
        exportedAt: Date = Date()
    ) throws -> Data {
        let export = try exportProject(projectID, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }

    /// The only path in this type that writes to `LocalNeuralMemoryStore`.
    /// A UI must call it only after a user explicitly approves this exact
    /// pending record. The automatic lifecycle adapter has no memory-store
    /// reference and cannot invoke it.
    ///
    /// The record is durably claimed before the graph write. If the process is
    /// interrupted after a successful graph capture but before queue cleanup,
    /// the claim remains and a later call fails closed instead of duplicating a
    /// graph fact. If graph capture itself throws, the claim is restored to
    /// pending so the user may review and retry it.
    public func approveFromUser(
        candidateID: String,
        projectID: String,
        approvalNote: String? = nil,
        memoryStore: LocalNeuralMemoryStore
    ) async throws -> LocalMemoryFact {
        try Self.validateProjectID(projectID)
        let normalizedNote = try Self.normalizedApprovalNote(approvalNote)
        guard let index = document.records.firstIndex(where: {
            $0.id == candidateID && $0.projectID == projectID
        }) else {
            throw NativeMemoryPendingCandidateQueueError.recordNotFound(id: candidateID, projectID: projectID)
        }
        let pendingRecord = document.records[index]
        guard pendingRecord.state == .pending else {
            throw NativeMemoryPendingCandidateQueueError.approvalInProgress(id: candidateID, projectID: projectID)
        }

        var claimedRecords = document.records
        claimedRecords[index] = NativeMemoryPendingCandidateRecord(
            candidate: pendingRecord.candidate,
            projectID: pendingRecord.projectID,
            enqueuedAt: pendingRecord.enqueuedAt,
            state: .approvalClaimed
        )
        try replaceDocument(records: claimedRecords)

        let candidate = pendingRecord.candidate
        let provenance = candidate.provenance
        let request = LocalMemoryCaptureRequest(
            projectID: projectID,
            fact: candidate.statement,
            source: LocalMemorySource(
                kind: .agentProposal,
                label: "User-approved automatic candidate (unverified model statement)",
                reference: Self.graphReference(for: provenance)
            ),
            provenance: LocalMemoryProvenance(
                capturedBy: "user",
                sourceRecordID: candidate.id,
                approvalNote: normalizedNote
            )
        )

        let fact: LocalMemoryFact
        do {
            // This acknowledgement is deliberately supplied only in this
            // user-named, explicit-approval method.
            fact = try await memoryStore.capture(request, approval: .userApproved)
        } catch {
            try? restorePendingRecord(pendingRecord)
            throw error
        }

        // Do not restore the pending record if cleanup fails: a durable claim
        // is safer than a possible duplicate approved graph fact.
        guard let claimedIndex = document.records.firstIndex(where: {
            $0.id == candidateID && $0.projectID == projectID
        }), document.records[claimedIndex].state == .approvalClaimed else {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }
        var remainingRecords = document.records
        remainingRecords.remove(at: claimedIndex)
        try replaceDocument(records: remainingRecords)
        return fact
    }

    private func restorePendingRecord(_ record: NativeMemoryPendingCandidateRecord) throws {
        guard let index = document.records.firstIndex(where: {
            $0.id == record.id && $0.projectID == record.projectID
        }), document.records[index].state == .approvalClaimed else {
            return
        }
        var restored = document.records
        restored[index] = NativeMemoryPendingCandidateRecord(
            candidate: record.candidate,
            projectID: record.projectID,
            enqueuedAt: record.enqueuedAt,
            state: .pending
        )
        try replaceDocument(records: restored)
    }

    private func replaceDocument(records: [NativeMemoryPendingCandidateRecord]) throws {
        let replacement = Document(
            formatVersion: Self.formatVersion,
            updatedAt: Date(),
            records: ordered(records)
        )
        try Self.validateDocument(replacement, configuration: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(replacement)
        guard data.count <= configuration.maximumDocumentBytes else {
            throw NativeMemoryPendingCandidateQueueError.queueCapacityReached(projectID: "local")
        }

        // Foundation applies complete Data Protection to the replacement file;
        // `.atomic` prevents a partially encoded document from replacing a
        // previously valid queue.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        document = replacement
    }

    private func ordered(_ records: [NativeMemoryPendingCandidateRecord]) -> [NativeMemoryPendingCandidateRecord] {
        records.sorted { lhs, rhs in
            if lhs.projectID != rhs.projectID { return lhs.projectID < rhs.projectID }
            if lhs.enqueuedAt != rhs.enqueuedAt { return lhs.enqueuedAt < rhs.enqueuedAt }
            return lhs.id < rhs.id
        }
    }

    private static func defaultFileURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeMemoryPendingCandidateQueueError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent("WaifuClaw", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("NativeMemoryPendingCandidates.json", isDirectory: false)
    }

    private static func loadDocument(
        at fileURL: URL,
        configuration: NativeMemoryPendingCandidateQueueConfiguration
    ) throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Document(formatVersion: formatVersion, updatedAt: Date(), records: [])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, byteCount <= configuration.maximumDocumentBytes else {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count == byteCount else {
                throw NativeMemoryPendingCandidateQueueError.corruptData
            }
            let decoded = try JSONDecoder().decode(Document.self, from: data)
            try validateDocument(decoded, configuration: configuration)
            return decoded
        } catch let error as NativeMemoryPendingCandidateQueueError {
            throw error
        } catch {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }
    }

    private static func validateDocument(
        _ document: Document,
        configuration: NativeMemoryPendingCandidateQueueConfiguration
    ) throws {
        guard document.formatVersion <= formatVersion else {
            throw NativeMemoryPendingCandidateQueueError.incompatibleFormatVersion(
                found: document.formatVersion,
                supported: formatVersion
            )
        }
        guard document.formatVersion == formatVersion,
              isFinite(document.updatedAt),
              document.records.count <= configuration.maximumPendingRecordsTotal
        else {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }

        var ids = Set<String>()
        var projectCounts: [String: Int] = [:]
        for record in document.records {
            try validateProjectID(record.projectID)
            try validate(
                record.candidate,
                projectID: record.projectID,
                maximumStatementCharacters: configuration.maximumStatementCharacters
            )
            guard isFinite(record.enqueuedAt), ids.insert(record.id).inserted else {
                throw NativeMemoryPendingCandidateQueueError.corruptData
            }
            projectCounts[record.projectID, default: 0] += 1
        }
        guard projectCounts.values.allSatisfy({ $0 <= configuration.maximumPendingRecordsPerProject }) else {
            throw NativeMemoryPendingCandidateQueueError.corruptData
        }
    }

    private static func validateProjectID(_ projectID: String) throws {
        guard NativeMemoryAutocapturePreferenceStore.isValidProjectID(projectID) else {
            throw NativeMemoryPendingCandidateQueueError.invalidProjectID
        }
    }

    private static func validate(
        _ candidate: NativeMemoryAutocaptureCandidate,
        projectID: String,
        maximumStatementCharacters: Int
    ) throws {
        let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty,
              statement == candidate.statement,
              statement.count <= maximumStatementCharacters,
              !containsSecretLookingContent(statement),
              candidate.verification == .unverifiedModelStatement,
              candidate.provenance.source == .finishedNativeAgentRun,
              candidate.provenance.projectID == projectID,
              candidate.provenance.terminalPhase == .finished,
              isFinite(candidate.provenance.completedAt),
              isExactCandidateID(candidate.id, runID: candidate.provenance.runID)
        else {
            throw NativeMemoryPendingCandidateQueueError.invalidCandidate
        }
    }

    private static func isExactCandidateID(_ candidateID: String, runID: UUID) -> Bool {
        let components = candidateID.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              String(components[0]) == runID.uuidString.lowercased(),
              let ordinal = Int(components[1]),
              ordinal >= 1,
              ordinal <= maximumCandidatesPerAppend,
              String(ordinal) == String(components[1])
        else {
            return false
        }
        return true
    }

    private static func normalized(
        _ configuration: NativeMemoryPendingCandidateQueueConfiguration
    ) -> NativeMemoryPendingCandidateQueueConfiguration {
        let perProject = min(max(configuration.maximumPendingRecordsPerProject, 1), 500)
        let total = min(
            max(configuration.maximumPendingRecordsTotal, perProject),
            maximumPendingRecordsHardLimit
        )
        return NativeMemoryPendingCandidateQueueConfiguration(
            maximumPendingRecordsPerProject: min(perProject, total),
            maximumPendingRecordsTotal: total,
            maximumStatementCharacters: min(max(configuration.maximumStatementCharacters, 80), 1_000),
            maximumDocumentBytes: min(max(configuration.maximumDocumentBytes, 4_096), maximumDocumentBytesHardLimit)
        )
    }

    private static func graphReference(for provenance: NativeMemoryAutocaptureProvenance) -> String {
        "run:\(provenance.runID.uuidString.lowercased());conversation:\(provenance.conversationID.uuidString.lowercased());message:\(provenance.assistantMessageID.uuidString.lowercased());verification:unverified-model-statement"
    }

    private static func normalizedApprovalNote(_ note: String?) throws -> String? {
        guard let note else { return nil }
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 512, !containsSecretLookingContent(normalized) else {
            throw NativeMemoryPendingCandidateQueueError.invalidApprovalNote
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
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
