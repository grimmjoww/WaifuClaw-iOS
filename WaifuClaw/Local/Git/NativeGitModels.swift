import Foundation

/// Where a cloned repository lives. No credentials or API keys are persisted.
enum NativeGitCloneLocation: String, Codable, Sendable, Hashable {
    case appSupport
    case workspaceFolder
}

/// A durable reference to a repository cloned by this iPhone.
struct NativeGitCloneRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let remoteURL: String
    let directoryName: String
    let location: NativeGitCloneLocation
    /// The canonical folder identity expected from the shared workspace bookmark.
    /// This prevents a later workspace selection from redirecting an old record.
    let workspaceFolderPath: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        remoteURL: String,
        directoryName: String,
        location: NativeGitCloneLocation,
        workspaceFolderPath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.remoteURL = remoteURL
        self.directoryName = directoryName
        self.location = location
        self.workspaceFolderPath = workspaceFolderPath
        self.createdAt = createdAt
    }
}

/// A concise repository state shown before a network or worktree operation.
struct NativeGitRepositoryState: Sendable, Equatable {
    enum Relationship: String, Sendable, Equatable {
        case unknown
        case upToDate
        case behind
        case ahead
        case diverged
        case noUpstream
        case detached
    }

    let branch: String
    let head: String
    let upstream: String?
    let dirtyEntries: Int
    let relationship: Relationship

    var isDirty: Bool { dirtyEntries > 0 }
}

enum NativeGitError: LocalizedError {
    case invalidRemoteURL(String)
    case invalidDestinationName
    case destinationAlreadyExists
    case workspaceUnavailable
    case notARepository
    case detachedHead
    case missingUpstream
    case dirtyWorktree(Int)
    case diverged
    case localBranchAhead
    case unsupportedRepositoryState(String)
    case cloneTooLarge
    case libgit2(operation: String, message: String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL(let reason):
            return "Enter a public HTTPS Git repository URL. \(reason)"
        case .invalidDestinationName:
            return "Choose a simple folder name using letters, numbers, dots, underscores, or hyphens."
        case .destinationAlreadyExists:
            return "That destination folder already exists. Nothing was overwritten."
        case .workspaceUnavailable:
            return "The selected Files folder is unavailable or its access grant needs to be renewed."
        case .notARepository:
            return "This folder is not an ordinary working Git repository."
        case .detachedHead:
            return "Pull is unavailable while HEAD is detached. Check out a local tracking branch first."
        case .missingUpstream:
            return "Pull is unavailable because the current branch has no upstream tracking branch."
        case .dirtyWorktree(let count):
            return "Pull is blocked because the worktree has \(count) changed or untracked item\(count == 1 ? "" : "s"). Commit, stash, or discard them first."
        case .diverged:
            return "Pull is blocked because local and upstream history diverged. Resolve it in another Git client; this app only fast-forwards."
        case .localBranchAhead:
            return "Pull is blocked because this branch is ahead of its upstream. This app does not push or rewrite history."
        case .unsupportedRepositoryState(let detail):
            return "Git operation is blocked: \(detail)"
        case .cloneTooLarge:
            return "This repository exceeded WaifuClaw's local clone limit and was discarded."
        case .libgit2(let operation, let message):
            return "Git \(operation) failed: \(message)"
        case .persistence(let message):
            return "Git metadata could not be saved: \(message)"
        }
    }
}

/// Accepts only anonymous, public-style HTTPS repository addresses. Authentication
/// is deliberately not implemented in this initial iPhone-only slice.
enum NativeGitURLValidator {
    static func validatedRemoteURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              isPublicHostname(host),
              components.port == nil || components.port == 443,
              let url = components.url
        else {
            throw NativeGitError.invalidRemoteURL("Only anonymous HTTPS addresses on a public hostname are supported; HTTP, SSH, local addresses, credentials, ports other than 443, queries, and fragments are refused.")
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard !parts.isEmpty,
              parts.allSatisfy(isSafePathComponent),
              parts.count > 1 || parts[0].hasSuffix(".git")
        else {
            throw NativeGitError.invalidRemoteURL("The path does not look like a repository path. Use a repository URL such as https://host/owner/repository.git.")
        }
        return url
    }

    private static func isPublicHostname(_ host: String) -> Bool {
        guard host.contains("."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.contains(":"),
              !host.allSatisfy({ $0.isNumber || $0 == "." })
        else { return false }
        return true
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != "..", component.count <= 100 else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) ||
            (97...122).contains(scalar.value) ||
            (48...57).contains(scalar.value) ||
            scalar.value == 45 || scalar.value == 95 || scalar.value == 46
        }
    }
}

enum NativeGitDestinationValidator {
    static func validatedDirectoryName(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 80,
              name != ".",
              name != "..",
              name.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) ||
                  (97...122).contains(scalar.value) ||
                  (48...57).contains(scalar.value) ||
                  scalar.value == 45 || scalar.value == 95 || scalar.value == 46
              })
        else { throw NativeGitError.invalidDestinationName }
        return name
    }

    static func suggestedDirectoryName(for remoteURL: URL) -> String {
        let candidate = remoteURL.deletingPathExtension().lastPathComponent
        return (try? validatedDirectoryName(candidate)) ?? "repository"
    }
}

/// Persists clone locations in Application Support. The file contains only clone
/// metadata; remote credentials are neither requested nor stored by this feature.
final class NativeGitMetadataStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeGitError.persistence("Application Support is unavailable.")
        }
        let folder = applicationSupport.appendingPathComponent("NativeGit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw NativeGitError.persistence(error.localizedDescription)
        }
        self.fileURL = folder.appendingPathComponent("clones.json")
    }

    func load() throws -> [NativeGitCloneRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([NativeGitCloneRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            throw NativeGitError.persistence("The saved clone list is unreadable. \(error.localizedDescription)")
        }
    }

    func save(_ records: [NativeGitCloneRecord]) throws {
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw NativeGitError.persistence(error.localizedDescription)
        }
    }
}
