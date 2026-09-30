import Foundation

/// The bounded content supplied to an approval UI. `relativePath` must be
/// rendered verbatim alongside the diff; it is never inferred from a model
/// summary. A preview whose proposal is no longer pending has no diff lines.
struct NativePatchApprovalPreview {
    let proposal: NativePatchProposal
    let relativePath: String
    let diffLines: [WorkspaceLineDiff.Line]
    let isCurrent: Bool
}

/// Result returned after an explicit UI approval attempt. The status and result
/// are durable evidence; a `.invalidated` outcome means no write was attempted
/// after detecting changed bytes.
struct NativePatchApprovalOutcome: Sendable {
    let proposal: NativePatchProposal
    let didWriteWorkspace: Bool
}

/// Implements the state machine behind a real on-device `propose_edit` tool.
///
/// Repository file contents and model text are untrusted input. They can only
/// populate a reason or a replacement candidate; neither can authorize a write.
/// The only write API is `approveAndApply`, which a SwiftUI confirmation action
/// must invoke after rendering `approvalPreview`'s exact path and bounded diff.
final class NativePatchWorkflow: @unchecked Sendable {
    static let maximumReplacementBytes = 16 * 1024
    static let maximumReasonBytes = 1_000
    static let maximumRelativePathBytes = 1_024
    static let maximumPreviewSourceLines = 100

    private struct UndoToken: Sendable {
        let projectID: String
        let record: WorkspaceUndoRecord
    }

    private let store: NativePatchProposalStore
    private let lock = NSLock()
    private var undoTokens: [UUID: UndoToken] = [:]

    init(store: NativePatchProposalStore) {
        self.store = store
    }

    convenience init(persistenceDirectoryURL: URL? = nil) throws {
        try self.init(store: NativePatchProposalStore(directoryURL: persistenceDirectoryURL))
    }

    /// Creates and persists a pending proposal from model-tool arguments. It
    /// always reads a real current `WorkspaceEditor` snapshot first, validates
    /// the model hash against that snapshot, and does not call any write API.
    func proposeEdit(
        _ request: NativePatchToolRequest,
        in project: NativePatchProject
    ) throws -> NativePatchProposal {
        try lock.withLock {
            guard request.projectID == project.projectID else {
                throw NativePatchError.projectIdentityMismatch
            }
            guard NativePatchDigest.isCanonicalSHA256(request.expectedSHA256) else {
                throw NativePatchError.invalidExpectedHash
            }
            guard request.relativePath.utf8.count <= Self.maximumRelativePathBytes else {
                throw WorkspaceEditorError.invalidPath
            }
            guard Data(request.newText.utf8).count <= Self.maximumReplacementBytes else {
                throw NativePatchError.replacementTooLarge
            }
            let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, Data(reason.utf8).count <= Self.maximumReasonBytes else {
                throw NativePatchError.invalidReason
            }
            if let expectedOriginalText = request.expectedOriginalText,
               Data(expectedOriginalText.utf8).count > WorkspaceEditor.maximumTextBytes {
                throw NativePatchError.originalTextTooLarge
            }

            let document = try project.makeEditor().readText(relativePath: request.relativePath)
            guard Data(document.originalText.utf8).count <= Self.maximumReplacementBytes else {
                throw NativePatchError.originalFileTooLarge
            }
            guard Self.lineCount(document.originalText) <= Self.maximumPreviewSourceLines,
                  Self.lineCount(request.newText) <= Self.maximumPreviewSourceLines else {
                throw NativePatchError.tooManyLines
            }
            guard request.expectedSHA256 == document.originalSHA256 else {
                throw NativePatchError.expectedHashMismatch
            }
            if let expectedOriginalText = request.expectedOriginalText,
               expectedOriginalText != document.originalText {
                throw NativePatchError.expectedHashMismatch
            }
            guard request.newText != document.originalText else {
                throw NativePatchError.replacementMatchesCurrentText
            }

            let now = Date()
            let proposal = NativePatchProposal(
                proposalID: UUID(),
                runID: request.runID,
                projectID: project.projectID,
                relativePath: document.relativePath,
                expectedSHA256: request.expectedSHA256,
                currentTextHash: document.originalSHA256,
                newText: request.newText,
                reason: reason,
                createdAt: now,
                updatedAt: now,
                status: .pending,
                result: nil
            )
            try store.save(proposal)
            return proposal
        }
    }

    /// Lists only this user-selected project's pending proposals. Folder URLs,
    /// bookmarks, and proposals for other project IDs are never exposed here.
    func pendingProposals(in project: NativePatchProject) throws -> [NativePatchProposal] {
        try store.proposals(projectID: project.projectID, statuses: [.pending])
    }

    /// Lists durable records only for the selected project's identity. Pass a
    /// status set for a filtered SwiftUI history, or `nil` for the full local
    /// audit trail for this project.
    func proposals(
        in project: NativePatchProject,
        statuses: Set<NativePatchProposalStatus>? = nil
    ) throws -> [NativePatchProposal] {
        try store.proposals(projectID: project.projectID, statuses: statuses)
    }

    func proposal(
        id: UUID,
        in project: NativePatchProject
    ) throws -> NativePatchProposal? {
        try store.proposal(id: id, projectID: project.projectID)
    }

    /// Re-reads the selected file for a bounded review diff. It never writes a
    /// workspace file. If bytes changed after proposal creation, the proposal
    /// is durably invalidated and no stale diff is returned for approval.
    func approvalPreview(
        proposalID: UUID,
        in project: NativePatchProject
    ) throws -> NativePatchApprovalPreview {
        try lock.withLock {
            let proposal = try requireProposal(proposalID, project: project)
            guard proposal.status == .pending else {
                return NativePatchApprovalPreview(
                    proposal: proposal,
                    relativePath: proposal.relativePath,
                    diffLines: [],
                    isCurrent: false
                )
            }
            let editor = try project.makeEditor()
            let document: WorkspaceTextDocument
            do {
                document = try editor.readText(relativePath: proposal.relativePath)
            } catch is WorkspaceEditorError {
                let invalidated = try invalidate(proposal, currentHash: nil)
                return NativePatchApprovalPreview(
                    proposal: invalidated,
                    relativePath: invalidated.relativePath,
                    diffLines: [],
                    isCurrent: false
                )
            }
            guard document.originalSHA256 == proposal.currentTextHash,
                  document.originalText != proposal.newText else {
                let invalidated = try invalidate(proposal, currentHash: document.originalSHA256)
                return NativePatchApprovalPreview(
                    proposal: invalidated,
                    relativePath: invalidated.relativePath,
                    diffLines: [],
                    isCurrent: false
                )
            }
            // WorkspaceLineDiff's LCS input is limited to 100 lines per side;
            // at most 201 preview rows (including its truncation notice) reach
            // SwiftUI even for a 128 KB source snapshot.
            let lines = WorkspaceLineDiff.make(
                original: document.originalText,
                draft: proposal.newText,
                limit: Self.maximumPreviewSourceLines
            )
            return NativePatchApprovalPreview(
                proposal: proposal,
                relativePath: proposal.relativePath,
                diffLines: lines,
                isCurrent: true
            )
        }
    }

    /// Call only from the positive action of a user confirmation dialog. The
    /// preflight snapshot prevents needless writes, while WorkspaceEditor.save
    /// repeats the hash check under NSFileCoordinator immediately before save.
    func approveAndApply(
        proposalID: UUID,
        in project: NativePatchProject
    ) throws -> NativePatchApprovalOutcome {
        try lock.withLock {
            let pending = try requireProposal(proposalID, project: project)
            guard pending.status == .pending else { throw NativePatchError.proposalNotPending }

            let editor = try project.makeEditor()
            let document: WorkspaceTextDocument
            do {
                document = try editor.readText(relativePath: pending.relativePath)
            } catch is WorkspaceEditorError {
                let invalidated = try invalidate(pending, currentHash: nil)
                return NativePatchApprovalOutcome(proposal: invalidated, didWriteWorkspace: false)
            }
            guard document.originalSHA256 == pending.currentTextHash,
                  document.originalText != pending.newText else {
                let invalidated = try invalidate(pending, currentHash: document.originalSHA256)
                return NativePatchApprovalOutcome(proposal: invalidated, didWriteWorkspace: false)
            }

            let approved = pending.updating(
                status: .approved,
                result: NativePatchProposalResult(
                    kind: .approved,
                    completedAt: Date(),
                    resultSHA256: document.originalSHA256,
                    message: "User approved the displayed patch."
                )
            )
            try store.save(approved)

            do {
                let save = try editor.save(document: document, draft: approved.newText)
                let applied = approved.updating(
                    status: .applied,
                    result: NativePatchProposalResult(
                        kind: .applied,
                        completedAt: Date(),
                        resultSHA256: save.document.originalSHA256,
                        message: "WorkspaceEditor saved the approved replacement."
                    )
                )
                try store.save(applied)
                // This is deliberately not encoded or written to disk. A fresh
                // app session cannot claim it can roll a file back.
                undoTokens[applied.proposalID] = UndoToken(
                    projectID: project.projectID,
                    record: save.undoRecord
                )
                return NativePatchApprovalOutcome(proposal: applied, didWriteWorkspace: true)
            } catch let error as WorkspaceEditorError where error == .concurrentModification {
                let invalidated = try invalidate(approved, currentHash: nil)
                return NativePatchApprovalOutcome(proposal: invalidated, didWriteWorkspace: false)
            } catch {
                let failed = approved.updating(
                    status: .failed,
                    result: NativePatchProposalResult(
                        kind: .failed,
                        completedAt: Date(),
                        resultSHA256: nil,
                        message: "WorkspaceEditor could not save the approved replacement."
                    )
                )
                try? store.save(failed)
                throw error
            }
        }
    }

    /// Records an explicit user rejection. No workspace read or write occurs.
    func reject(
        proposalID: UUID,
        in project: NativePatchProject
    ) throws -> NativePatchProposal {
        try lock.withLock {
            let pending = try requireProposal(proposalID, project: project)
            guard pending.status == .pending else { throw NativePatchError.proposalNotPending }
            let rejected = pending.updating(
                status: .rejected,
                result: NativePatchProposalResult(
                    kind: .rejected,
                    completedAt: Date(),
                    resultSHA256: nil,
                    message: "User rejected the proposed patch."
                )
            )
            try store.save(rejected)
            return rejected
        }
    }

    /// Reverts only a save made by this workflow in the current process. The
    /// underlying WorkspaceEditor refuses changed bytes under coordination; an
    /// undo conflict invalidates the record rather than overwriting the file.
    func undoLastApprovedSave(
        proposalID: UUID,
        in project: NativePatchProject
    ) throws -> NativePatchApprovalOutcome {
        try lock.withLock {
            var proposal = try requireProposal(proposalID, project: project)
            guard proposal.status == .applied else { throw NativePatchError.undoUnavailable }
            guard let token = undoTokens[proposalID] else { throw NativePatchError.undoUnavailable }
            guard token.projectID == project.projectID else { throw NativePatchError.undoProjectMismatch }

            do {
                let restored = try project.makeEditor().undoLastSave(token.record)
                proposal = proposal.updating(
                    status: .undone,
                    result: NativePatchProposalResult(
                        kind: .undone,
                        completedAt: Date(),
                        resultSHA256: restored.originalSHA256,
                        message: "WorkspaceEditor restored the pre-approval bytes."
                    )
                )
                try store.save(proposal)
                undoTokens.removeValue(forKey: proposalID)
                return NativePatchApprovalOutcome(proposal: proposal, didWriteWorkspace: true)
            } catch let error as WorkspaceEditorError where error == .concurrentModification {
                let invalidated = try invalidate(proposal, currentHash: nil)
                undoTokens.removeValue(forKey: proposalID)
                return NativePatchApprovalOutcome(proposal: invalidated, didWriteWorkspace: false)
            }
        }
    }

    private func requireProposal(
        _ proposalID: UUID,
        project: NativePatchProject
    ) throws -> NativePatchProposal {
        guard let proposal = try store.proposal(id: proposalID, projectID: project.projectID) else {
            throw NativePatchError.proposalNotFound
        }
        guard proposal.projectID == project.projectID else {
            throw NativePatchError.projectIdentityMismatch
        }
        return proposal
    }

    private static func lineCount(_ text: String) -> Int {
        text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    private func invalidate(
        _ proposal: NativePatchProposal,
        currentHash: String?
    ) throws -> NativePatchProposal {
        let invalidated = proposal.updating(
            status: .invalidated,
            result: NativePatchProposalResult(
                kind: .invalidated,
                completedAt: Date(),
                resultSHA256: currentHash,
                message: "The workspace file changed, so this patch was not applied."
            )
        )
        try store.save(invalidated)
        undoTokens.removeValue(forKey: proposal.proposalID)
        return invalidated
    }
}
