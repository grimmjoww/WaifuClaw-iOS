import Foundation

/// Errors for the Team-only history file. This is separate from LocalRunStore:
/// the latter remains the source of truth for conversations, runs, and events.
enum NativeTeamWorkflowStoreError: LocalizedError, Sendable {
    case applicationSupportUnavailable
    case corruptHistory
    case workflowNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local Team history storage is unavailable."
        case .corruptHistory:
            return "Local Team history could not be read safely."
        case .workflowNotFound:
            return "The requested Team workflow no longer exists in local history."
        }
    }
}

/// Durable, bounded metadata linking Team orchestration to LocalRunStore IDs.
/// Credentials never enter this store; the configured BYOK provider is held only
/// in memory while a workflow is running.
actor NativeTeamWorkflowStore {
    private static let schemaVersion = 1
    private let fileURL: URL
    private var records: [UUID: NativeTeamWorkflowRecord]

    init(directoryURL: URL? = nil) throws {
        let directory = try directoryURL ?? Self.defaultDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("NativeTeamWorkflowHistory.json", isDirectory: false)

        var loaded = try Self.load(fileURL: fileURL)
        let didRecoverInterruptedWorkflow = Self.recoverInterruptedWorkflows(&loaded)
        records = Self.trimHistory(loaded)
        if didRecoverInterruptedWorkflow {
            try Self.persist(records, to: fileURL)
        }
    }

    /// Newest updated workflow first. At most `NativeTeamLimits.historyCount`
    /// records are retained in this Team-specific history file.
    func list() -> [NativeTeamWorkflowRecord] {
        Self.sorted(records.values)
    }

    func workflow(id: UUID) throws -> NativeTeamWorkflowRecord {
        guard let record = records[id] else {
            throw NativeTeamWorkflowStoreError.workflowNotFound(id)
        }
        return record
    }

    func create(
        userGoal: String,
        projectReadAllowed: Bool,
        workers: [NativeTeamWorkerEvidence],
        supervisor: NativeTeamSupervisorEvidence
    ) throws -> NativeTeamWorkflowRecord {
        let record = NativeTeamWorkflowRecord(
            userGoal: userGoal,
            projectReadAllowed: projectReadAllowed,
            workers: workers,
            supervisor: supervisor
        )
        try replace(record)
        return record
    }

    func replaceWorkers(
        _ workerEvidence: [NativeTeamWorkerEvidence],
        workflowID: UUID
    ) throws -> NativeTeamWorkflowRecord {
        try mutate(workflowID) { record in
            // Preserve the fixed display order even though worker tasks finish
            // nondeterministically under the bounded task group.
            record.workers = NativeTeamRole.workerRoles.compactMap { role in
                workerEvidence.first(where: { $0.role == role })
                    ?? record.workers.first(where: { $0.role == role })
            }
        }
    }

    func beginSynthesis(workflowID: UUID) throws -> NativeTeamWorkflowRecord {
        try mutate(workflowID) { record in
            record.phase = .synthesizing
            record.statusNote = "Worker evidence is saved locally; the supervisor is synthesizing the available evidence."
        }
    }

    func finish(
        workflowID: UUID,
        phase: NativeTeamWorkflowPhase,
        supervisor: NativeTeamSupervisorEvidence,
        finalSynthesis: String?,
        statusNote: String?
    ) throws -> NativeTeamWorkflowRecord {
        try mutate(workflowID) { record in
            record.phase = phase
            record.supervisor = supervisor
            record.finalSynthesis = finalSynthesis.map {
                NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.outputExcerptCharacters)
            }
            record.statusNote = statusNote.map {
                NativeTeamLimits.clamp($0, maximum: NativeTeamLimits.statusCharacters)
            }
        }
    }

    /// Converts active state to a truthful terminal state after an explicit user
    /// cancellation. Completed worker evidence is kept; unfinished participants
    /// are marked cancelled rather than reported as successful.
    func cancel(workflowID: UUID) throws -> NativeTeamWorkflowRecord {
        try mutate(workflowID) { record in
            record.phase = .cancelled
            record.workers = record.workers.map { worker in
                guard worker.runPhase != .finished && worker.runPhase != .failed else { return worker }
                var cancelled = worker
                cancelled.runPhase = .cancelled
                cancelled.errorMessage = cancelled.errorMessage ?? "Cancelled before a completed response was recorded."
                return cancelled
            }
            if record.supervisor.runPhase != .finished && record.supervisor.runPhase != .failed {
                record.supervisor.runPhase = .cancelled
                record.supervisor.errorMessage = record.supervisor.errorMessage ?? "Cancelled before synthesis completed."
            }
            record.statusNote = "Stopped by the user or system. This workflow was not completed."
        }
    }

    func fail(workflowID: UUID, note: String) throws -> NativeTeamWorkflowRecord {
        try mutate(workflowID) { record in
            record.phase = .failed
            record.statusNote = NativeTeamLimits.clamp(note, maximum: NativeTeamLimits.statusCharacters)
        }
    }

    private func mutate(
        _ workflowID: UUID,
        change: (inout NativeTeamWorkflowRecord) -> Void
    ) throws -> NativeTeamWorkflowRecord {
        guard var record = records[workflowID] else {
            throw NativeTeamWorkflowStoreError.workflowNotFound(workflowID)
        }
        change(&record)
        record.updatedAt = Date()
        try replace(record)
        return record
    }

    private func replace(_ record: NativeTeamWorkflowRecord) throws {
        records[record.id] = record
        records = Self.trimHistory(records)
        try Self.persist(records, to: fileURL)
    }

    private static func defaultDirectoryURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeTeamWorkflowStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("WaifuClaw", isDirectory: true)
            .appendingPathComponent("Team", isDirectory: true)
    }

    private static func load(fileURL: URL) throws -> [UUID: NativeTeamWorkflowRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let history = try JSONDecoder().decode(PersistedHistory.self, from: data)
            guard history.schemaVersion == schemaVersion else {
                throw NativeTeamWorkflowStoreError.corruptHistory
            }
            var decoded: [UUID: NativeTeamWorkflowRecord] = [:]
            for record in history.records {
                guard decoded[record.id] == nil else {
                    throw NativeTeamWorkflowStoreError.corruptHistory
                }
                decoded[record.id] = record
            }
            return decoded
        } catch let error as NativeTeamWorkflowStoreError {
            throw error
        } catch {
            throw NativeTeamWorkflowStoreError.corruptHistory
        }
    }

    private static func persist(
        _ records: [UUID: NativeTeamWorkflowRecord],
        to fileURL: URL
    ) throws {
        let history = PersistedHistory(
            schemaVersion: schemaVersion,
            records: sorted(records.values)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(history)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    @discardableResult
    private static func recoverInterruptedWorkflows(
        _ records: inout [UUID: NativeTeamWorkflowRecord]
    ) -> Bool {
        var changed = false
        for id in records.keys {
            guard var record = records[id], !record.phase.isTerminal else { continue }
            record.phase = .interrupted
            record.statusNote = "The app stopped before this workflow finished. Saved worker evidence is retained; it was not completed."
            record.updatedAt = Date()
            records[id] = record
            changed = true
        }
        return changed
    }

    private static func trimHistory(
        _ records: [UUID: NativeTeamWorkflowRecord]
    ) -> [UUID: NativeTeamWorkflowRecord] {
        Dictionary(uniqueKeysWithValues: sorted(records.values)
            .prefix(NativeTeamLimits.historyCount)
            .map { ($0.id, $0) })
    }

    private static func sorted<C: Collection>(
        _ records: C
    ) -> [NativeTeamWorkflowRecord] where C.Element == NativeTeamWorkflowRecord {
        records.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private struct PersistedHistory: Codable {
        let schemaVersion: Int
        let records: [NativeTeamWorkflowRecord]
    }
}
