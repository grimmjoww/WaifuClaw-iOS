import CryptoKit
import Foundation

/// The only project capability accepted by the patch workflow. Construct this
/// immediately from a folder URL returned by the user's Files picker (or a
/// still-valid security-scoped bookmark), never from model output.
struct NativePatchProject: Sendable {
    let rootURL: URL
    let projectID: String

    init(userSelectedFolderURL: URL) throws {
        // WorkspaceEditor validates the directory while holding its security
        // scope. The workflow creates a fresh editor for every read/write so
        // access is never retained beyond a user action.
        _ = try WorkspaceEditor(rootURL: userSelectedFolderURL)
        rootURL = userSelectedFolderURL
        projectID = NativeProjectIdentity.id(for: userSelectedFolderURL)
    }

    func makeEditor() throws -> WorkspaceEditor {
        try WorkspaceEditor(rootURL: rootURL)
    }
}

/// JSON shape for the model tool named `propose_edit`. It deliberately has no
/// approval or write flag: receiving this request can only create a pending
/// proposal, never change a workspace file.
struct NativePatchModelEditArguments: Codable, Sendable, Equatable {
    let relativePath: String
    let expectedSHA256: String
    let newText: String
    let reason: String
    let expectedOriginalText: String?

    init(
        relativePath: String,
        expectedSHA256: String,
        newText: String,
        reason: String,
        expectedOriginalText: String? = nil
    ) {
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        self.newText = newText
        self.reason = reason
        self.expectedOriginalText = expectedOriginalText
    }
}

/// Context-bound record passed from the engine to the workflow. The preferred
/// initializer derives run and project identity from trusted app state rather
/// than accepting either identifier from a model tool payload.
struct NativePatchToolRequest: Codable, Sendable, Equatable {
    let runID: UUID
    let projectID: String
    let relativePath: String
    let expectedSHA256: String
    let newText: String
    let reason: String

    /// When supplied, this is checked against the just-read editor snapshot.
    /// It is never persisted, avoiding retention of the original full source.
    let expectedOriginalText: String?

    init(
        runID: UUID,
        projectID: String,
        relativePath: String,
        expectedSHA256: String,
        newText: String,
        reason: String,
        expectedOriginalText: String? = nil
    ) {
        self.runID = runID
        self.projectID = projectID
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        self.newText = newText
        self.reason = reason
        self.expectedOriginalText = expectedOriginalText
    }

    init(
        modelArguments: NativePatchModelEditArguments,
        actualRunID: UUID,
        selectedProject: NativePatchProject
    ) {
        self.init(
            runID: actualRunID,
            projectID: selectedProject.projectID,
            relativePath: modelArguments.relativePath,
            expectedSHA256: modelArguments.expectedSHA256,
            newText: modelArguments.newText,
            reason: modelArguments.reason,
            expectedOriginalText: modelArguments.expectedOriginalText
        )
    }
}

enum NativePatchProposalStatus: String, Codable, Sendable, Equatable {
    /// Created by a model tool, but no workspace bytes have been touched.
    case pending
    /// The UI explicitly confirmed the displayed diff and path; save is next.
    case approved
    /// The UI explicitly declined the proposal. It can never be applied.
    case rejected
    /// WorkspaceEditor saved the proposed replacement after its conflict check.
    case applied
    /// The file bytes changed, so the proposal or its in-memory undo is unsafe.
    case invalidated
    /// A non-conflict write/read failure was recorded without claiming success.
    case failed
    /// The in-memory WorkspaceEditor undo token was successfully used.
    case undone
}

enum NativePatchResultKind: String, Codable, Sendable, Equatable {
    case approved
    case applied
    case rejected
    case invalidated
    case failed
    case undone
}

/// Auditable outcome metadata. This never stores a credential, a bookmark, or
/// original source text. `resultSHA256` is the actual saved/restored hash only.
struct NativePatchProposalResult: Codable, Sendable, Equatable {
    let kind: NativePatchResultKind
    let completedAt: Date
    let resultSHA256: String?
    let message: String
}

/// Durable, typed record for one proposed whole-file replacement.
///
/// Only `newText` (capped at 16 KB) is retained so pending work can survive a
/// relaunch. The current/original source is never persisted: approval re-reads
/// the selected workspace and refuses any changed hash. The enclosing store is
/// additionally placed under iOS complete file protection.
struct NativePatchProposal: Codable, Identifiable, Sendable, Equatable {
    let proposalID: UUID
    let runID: UUID
    let projectID: String
    let relativePath: String
    let expectedSHA256: String
    let currentTextHash: String
    let newText: String
    let reason: String
    let createdAt: Date
    let updatedAt: Date
    let status: NativePatchProposalStatus
    let result: NativePatchProposalResult?

    var id: UUID { proposalID }

    func updating(
        status: NativePatchProposalStatus,
        result: NativePatchProposalResult? = nil,
        at date: Date = Date()
    ) -> NativePatchProposal {
        NativePatchProposal(
            proposalID: proposalID,
            runID: runID,
            projectID: projectID,
            relativePath: relativePath,
            expectedSHA256: expectedSHA256,
            currentTextHash: currentTextHash,
            newText: newText,
            reason: reason,
            createdAt: createdAt,
            updatedAt: date,
            status: status,
            result: result
        )
    }
}

enum NativePatchError: Error, LocalizedError, Equatable {
    case projectIdentityMismatch
    case invalidExpectedHash
    case expectedHashMismatch
    case replacementTooLarge
    case originalFileTooLarge
    case tooManyLines
    case invalidReason
    case originalTextTooLarge
    case replacementMatchesCurrentText
    case proposalNotFound
    case proposalNotPending
    case undoUnavailable
    case undoProjectMismatch

    var errorDescription: String? {
        switch self {
        case .projectIdentityMismatch:
            return "This proposal does not belong to the selected project folder."
        case .invalidExpectedHash:
            return "The proposed expected SHA-256 is invalid."
        case .expectedHashMismatch:
            return "The file no longer matches the model's expected SHA-256. Reload it before proposing an edit."
        case .replacementTooLarge:
            return "A proposed replacement is limited to 16 KB of UTF-8 text."
        case .originalFileTooLarge:
            return "Automatic edit proposals are limited to existing files up to 16 KB; open larger files in Workspace."
        case .tooManyLines:
            return "Automatic edit proposals are limited to 100 lines so every change is visible before approval."
        case .invalidReason:
            return "A short, non-empty reason is required for a proposed edit."
        case .originalTextTooLarge:
            return "The optional original-text check is larger than the safe text-file limit."
        case .replacementMatchesCurrentText:
            return "The proposed replacement is identical to the current file."
        case .proposalNotFound:
            return "This patch proposal was not found in the selected project."
        case .proposalNotPending:
            return "Only a pending patch proposal can be approved or rejected."
        case .undoUnavailable:
            return "Undo is available only while this app session still holds the actual save token."
        case .undoProjectMismatch:
            return "The undo token belongs to a different selected project."
        }
    }
}

enum NativePatchStoreError: Error, LocalizedError {
    case applicationSupportUnavailable
    case invalidStoreURL
    case corruptProposal

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .invalidStoreURL:
            return "The patch proposal store must use a local file URL."
        case .corruptProposal:
            return "A saved patch proposal could not be read safely."
        }
    }
}

/// Synchronous, lock-protected persistence for proposal records. The store has
/// no credential fields and never writes a workspace file.
final class NativePatchProposalStore: @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            directory = try Self.defaultDirectoryURL(fileManager: fileManager)
        }
        guard directory.isFileURL else { throw NativePatchStoreError.invalidStoreURL }
        self.rootURL = directory
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try protect(directory)
    }

    func save(_ proposal: NativePatchProposal) throws {
        try lock.withLock {
            let directory = try projectDirectoryURL(for: proposal.projectID)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try protect(directory)
            let data = try encoder.encode(proposal)
            let destination = directory.appendingPathComponent(proposal.proposalID.uuidString + ".json")
            try data.write(to: destination, options: .atomic)
            try protect(destination)
        }
    }

    func proposal(id: UUID, projectID: String) throws -> NativePatchProposal? {
        try lock.withLock {
            let url = try projectDirectoryURL(for: projectID)
                .appendingPathComponent(id.uuidString + ".json")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let proposal = try decodeProposal(at: url)
            guard proposal.projectID == projectID, proposal.proposalID == id else {
                throw NativePatchStoreError.corruptProposal
            }
            return proposal
        }
    }

    /// Reads records only from the current project's opaque directory. A record
    /// also must carry the requested exact project ID before it is returned.
    func proposals(projectID: String, statuses: Set<NativePatchProposalStatus>? = nil) throws -> [NativePatchProposal] {
        try lock.withLock {
            let directory = try projectDirectoryURL(for: projectID)
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let proposals = try urls.compactMap { url -> NativePatchProposal? in
                guard url.pathExtension == "json",
                      url.deletingPathExtension().lastPathComponent == UUID(uuidString: url.deletingPathExtension().lastPathComponent)?.uuidString,
                      (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                let proposal = try decodeProposal(at: url)
                guard proposal.projectID == projectID else { return nil }
                guard statuses?.contains(proposal.status) ?? true else { return nil }
                return proposal
            }
            return proposals.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.proposalID.uuidString < $1.proposalID.uuidString
            }
        }
    }

    private func decodeProposal(at url: URL) throws -> NativePatchProposal {
        do {
            return try decoder.decode(NativePatchProposal.self, from: Data(contentsOf: url))
        } catch {
            throw NativePatchStoreError.corruptProposal
        }
    }

    private func projectDirectoryURL(for projectID: String) throws -> URL {
        guard !projectID.isEmpty, projectID.utf8.count <= 512 else {
            throw NativePatchStoreError.corruptProposal
        }
        // The project ID is retained inside each Codable record; its directory
        // component is a digest, never an untrusted path segment.
        let name = NativePatchDigest.sha256(Data(projectID.utf8))
        return rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NativePatchStoreError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent("WaifuClaw", isDirectory: true)
            .appendingPathComponent("NativePatchProposals", isDirectory: true)
    }
}

enum NativePatchDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}
