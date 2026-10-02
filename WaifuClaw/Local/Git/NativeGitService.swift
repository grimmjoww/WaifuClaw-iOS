import Foundation
import SwiftGitX
import libgit2

struct NativeGitTransferProgress: Sendable, Equatable {
    let receivedObjects: Int
    let totalObjects: Int
    let receivedBytes: Int

    var fractionCompleted: Double? {
        guard totalObjects > 0 else { return nil }
        return min(1, Double(receivedObjects) / Double(totalObjects))
    }
}

/// Performs all network and worktree operations through SwiftGitX/libgit2.
/// It never starts a Git executable, runs hooks, invokes LFS, initializes
/// submodules, force-checks out, hard-resets, pushes, or stores credentials.
final class NativeGitService {
    static let workspaceBookmarkKey = "native.git.cloneDestinationBookmark"
    private static let activeProjectBookmarkKey = "native.workspace.folderBookmark"

    private let metadataStore: NativeGitMetadataStore
    private let fileManager: FileManager
    private let maximumCloneObjects = 250_000
    private let maximumCloneBytes = 300 * 1_024 * 1_024

    init(
        metadataStore: NativeGitMetadataStore? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.metadataStore = try metadataStore ?? NativeGitMetadataStore()
        self.fileManager = fileManager
    }

    func listClones() throws -> [NativeGitCloneRecord] {
        try metadataStore.load().sorted { $0.createdAt > $1.createdAt }
    }

    func clone(
        remoteText: String,
        directoryName: String,
        location: NativeGitCloneLocation,
        progress: @escaping (NativeGitTransferProgress) -> Void
    ) async throws -> NativeGitCloneRecord {
        let remoteURL = try NativeGitURLValidator.validatedRemoteURL(remoteText)
        let safeDirectoryName = try NativeGitDestinationValidator.validatedDirectoryName(directoryName)

        let destination: URL
        let workspacePath: String?
        var workspaceRootToRelease: URL?
        switch location {
        case .appSupport:
            let root = try appRepositoriesRoot()
            destination = try destinationURL(root: root, name: safeDirectoryName)
            workspacePath = nil
        case .workspaceFolder:
            let root = try resolvedWorkspaceRoot()
            guard root.startAccessingSecurityScopedResource() else {
                throw NativeGitError.workspaceUnavailable
            }
            workspaceRootToRelease = root
            destination = try destinationURL(root: root, name: safeDirectoryName)
            workspacePath = root.standardizedFileURL.resolvingSymlinksInPath().path
        }
        defer {
            if let workspaceRootToRelease {
                workspaceRootToRelease.stopAccessingSecurityScopedResource()
            }
        }

        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NativeGitError.destinationAlreadyExists
        }

        let limiter = NativeGitCloneLimiter(
            maximumObjects: maximumCloneObjects,
            maximumBytes: maximumCloneBytes
        )
        do {
            // SwiftGitX uses libgit2's safe checkout strategy. Its clone options
            // do not configure submodule recursion or an external credential helper.
            let cloneTask = Task<Repository, Error> {
                try await Repository.clone(from: remoteURL, to: destination) { transfer in
                    limiter.record(transfer)
                    progress(NativeGitTransferProgress(
                        receivedObjects: transfer.receivedObjects,
                        totalObjects: transfer.totalObjects,
                        receivedBytes: transfer.receivedBytes
                    ))
                }
            }
            limiter.cancelClone = { cloneTask.cancel() }
            if limiter.exceeded { cloneTask.cancel() }
            _ = try await cloneTask.value

            // SwiftGitX observes Task cancellation in its transfer callback. If
            // the callback crossed a ceiling before cancellation took effect, do
            // not retain the completed clone.
            guard !limiter.exceeded else {
                try? fileManager.removeItem(at: destination)
                throw NativeGitError.cloneTooLarge
            }

            let record = NativeGitCloneRecord(
                remoteURL: remoteURL.absoluteString,
                directoryName: safeDirectoryName,
                location: location,
                workspaceFolderPath: workspacePath
            )
            do {
                var records = try metadataStore.load()
                records.append(record)
                try metadataStore.save(records)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            return record
        } catch {
            if limiter.exceeded {
                try? fileManager.removeItem(at: destination)
                throw NativeGitError.cloneTooLarge
            }
            // The destination was proven absent before this operation. Deleting a
            // failed clone therefore cannot delete an existing user folder.
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    func inspect(_ record: NativeGitCloneRecord) throws -> NativeGitRepositoryState {
        try withRepositoryURL(record) { path in
            let repository = try Repository.open(at: path)
            guard !repository.isBare else { throw NativeGitError.notARepository }
            guard !repository.isHEADUnborn else {
                throw NativeGitError.unsupportedRepositoryState("the repository has no initial commit")
            }
            guard !repository.isHEADDetached else {
                return NativeGitRepositoryState(
                    branch: "Detached HEAD",
                    head: "Detached",
                    upstream: nil,
                    dirtyEntries: try repository.status().count,
                    relationship: .detached
                )
            }

            let branch = try repository.branch.current
            let upstream = branch.upstream
            let relationship: NativeGitRepositoryState.Relationship
            if upstream == nil {
                relationship = .noUpstream
            } else {
                relationship = try NativeGitCRepository.relationship(at: path)
            }

            return NativeGitRepositoryState(
                branch: branch.name,
                head: branch.target.id.abbreviated,
                upstream: upstream?.fullName,
                dirtyEntries: try repository.status().count,
                relationship: relationship
            )
        }
    }

    /// Downloads refs only. Fetch never updates HEAD or the worktree.
    func fetch(_ record: NativeGitCloneRecord) async throws -> NativeGitRepositoryState {
        try await withRepositoryURLAsync(record) { path in
            let repository = try Repository.open(at: path)
            guard !repository.isBare else { throw NativeGitError.notARepository }
            let remote = try self.fetchRemote(for: repository)
            try await repository.fetch(remote: remote)
            return try self.inspectAtPath(path)
        }
    }

    /// Updates only when the current local tracking branch is clean and the
    /// fetched upstream is a strict descendant. Divergence, force updates,
    /// detached HEAD, and any dirty state are rejected before checkout.
    func pullFastForward(_ record: NativeGitCloneRecord) async throws -> NativeGitRepositoryState {
        try await withRepositoryURLAsync(record) { path in
            let beforeFetch = try self.inspectAtPath(path)
            try self.requireCleanFastForwardCandidate(beforeFetch)

            let repository = try Repository.open(at: path)
            let remote = try self.fetchRemote(for: repository)
            try await repository.fetch(remote: remote)

            // Fetch changes refs but not files. Still re-read status immediately
            // before checkout so an edit made while the network call was running
            // is never overwritten.
            let beforeCheckout = try self.inspectAtPath(path)
            try self.requireCleanFastForwardCandidate(beforeCheckout)
            guard beforeCheckout.relationship == .behind else {
                return beforeCheckout
            }

            try NativeGitCRepository.fastForward(at: path)
            return try self.inspectAtPath(path)
        }
    }

    func selectWorkspaceFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard isReadableNonSymlinkDirectory(url) else { throw NativeGitError.workspaceUnavailable }
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.workspaceBookmarkKey)
    }

    /// Make a real cloned repository the project used by Agent, Workspace and
    /// Memory. Choosing a Git clone destination alone does not change the
    /// active project; this is a separate user-initiated operation.
    func useCloneAsActiveProject(_ record: NativeGitCloneRecord) throws {
        try withRepositoryURL(record) { url in
            let repository = try Repository.open(at: url)
            guard !repository.isBare else { throw NativeGitError.notARepository }
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.activeProjectBookmarkKey)
        }
    }

    private func inspectAtPath(_ path: URL) throws -> NativeGitRepositoryState {
        let repository = try Repository.open(at: path)
        guard !repository.isBare else { throw NativeGitError.notARepository }
        guard !repository.isHEADUnborn else {
            throw NativeGitError.unsupportedRepositoryState("the repository has no initial commit")
        }
        guard !repository.isHEADDetached else {
            return NativeGitRepositoryState(
                branch: "Detached HEAD",
                head: "Detached",
                upstream: nil,
                dirtyEntries: try repository.status().count,
                relationship: .detached
            )
        }

        let branch = try repository.branch.current
        let upstream = branch.upstream
        return NativeGitRepositoryState(
            branch: branch.name,
            head: branch.target.id.abbreviated,
            upstream: upstream?.fullName,
            dirtyEntries: try repository.status().count,
            relationship: upstream == nil ? .noUpstream : try NativeGitCRepository.relationship(at: path)
        )
    }

    private func requireCleanFastForwardCandidate(_ state: NativeGitRepositoryState) throws {
        guard !state.isDirty else { throw NativeGitError.dirtyWorktree(state.dirtyEntries) }
        switch state.relationship {
        case .detached:
            throw NativeGitError.detachedHead
        case .noUpstream:
            throw NativeGitError.missingUpstream
        case .diverged:
            throw NativeGitError.diverged
        case .ahead:
            throw NativeGitError.localBranchAhead
        case .unknown:
            throw NativeGitError.unsupportedRepositoryState("the branch relationship could not be proven")
        case .upToDate, .behind:
            return
        }
    }

    private func fetchRemote(for repository: Repository) throws -> Remote {
        if !repository.isHEADDetached,
           let branch = try? repository.branch.current,
           let remote = branch.remote {
            _ = try NativeGitURLValidator.validatedRemoteURL(remote.url.absoluteString)
            return remote
        }
        guard let origin = repository.remote["origin"] else {
            throw NativeGitError.unsupportedRepositoryState("there is no upstream remote or origin remote")
        }
        _ = try NativeGitURLValidator.validatedRemoteURL(origin.url.absoluteString)
        return origin
    }

    private func appRepositoriesRoot() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw NativeGitError.workspaceUnavailable }
        let root = applicationSupport
            .appendingPathComponent("NativeGit", isDirectory: true)
            .appendingPathComponent("Repositories", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw NativeGitError.persistence(error.localizedDescription)
        }
        return root
    }

    private func destinationURL(root: URL, name: String) throws -> URL {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path.hasPrefix(canonicalRoot.path + "/") else {
            throw NativeGitError.invalidDestinationName
        }
        return destination
    }

    private func withRepositoryURL<T>(
        _ record: NativeGitCloneRecord,
        operation: (URL) throws -> T
    ) throws -> T {
        _ = try NativeGitDestinationValidator.validatedDirectoryName(record.directoryName)
        switch record.location {
        case .appSupport:
            return try operation(try repositoryURL(for: record))
        case .workspaceFolder:
            let root = try resolvedWorkspaceRoot(expectedPath: record.workspaceFolderPath)
            guard root.startAccessingSecurityScopedResource() else {
                throw NativeGitError.workspaceUnavailable
            }
            defer { root.stopAccessingSecurityScopedResource() }
            return try operation(try destinationURL(root: root, name: record.directoryName))
        }
    }

    private func withRepositoryURLAsync<T>(
        _ record: NativeGitCloneRecord,
        operation: (URL) async throws -> T
    ) async throws -> T {
        _ = try NativeGitDestinationValidator.validatedDirectoryName(record.directoryName)
        switch record.location {
        case .appSupport:
            return try await operation(try repositoryURL(for: record))
        case .workspaceFolder:
            let root = try resolvedWorkspaceRoot(expectedPath: record.workspaceFolderPath)
            let accessing = root.startAccessingSecurityScopedResource()
            guard accessing else { throw NativeGitError.workspaceUnavailable }
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            return try await operation(try destinationURL(root: root, name: record.directoryName))
        }
    }

    private func repositoryURL(for record: NativeGitCloneRecord) throws -> URL {
        _ = try NativeGitDestinationValidator.validatedDirectoryName(record.directoryName)
        switch record.location {
        case .appSupport:
            return try destinationURL(root: appRepositoriesRoot(), name: record.directoryName)
        case .workspaceFolder:
            let root = try resolvedWorkspaceRoot(expectedPath: record.workspaceFolderPath)
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            return try destinationURL(root: root, name: record.directoryName)
        }
    }

    private func resolvedWorkspaceRoot(expectedPath: String? = nil) throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.workspaceBookmarkKey) else {
            throw NativeGitError.workspaceUnavailable
        }
        var isStale = false
        let root: URL
        do {
            root = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NativeGitError.workspaceUnavailable
        }
        guard !isStale, isReadableNonSymlinkDirectory(root) else {
            throw NativeGitError.workspaceUnavailable
        }
        let canonicalPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard expectedPath == nil || expectedPath == canonicalPath else {
            throw NativeGitError.workspaceUnavailable
        }
        return root
    }

    private func isReadableNonSymlinkDirectory(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isReadableKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true && values?.isReadable == true
    }
}

private final class NativeGitCloneLimiter {
    private let maximumObjects: Int
    private let maximumBytes: Int
    private(set) var exceeded = false
    var cancelClone: (() -> Void)?

    init(maximumObjects: Int, maximumBytes: Int) {
        self.maximumObjects = maximumObjects
        self.maximumBytes = maximumBytes
    }

    func record(_ progress: TransferProgress) {
        if !exceeded, (progress.totalObjects > maximumObjects || progress.receivedBytes > maximumBytes) {
            exceeded = true
            cancelClone?()
        }
    }
}

/// Minimal raw libgit2 calls necessary for a safe fast-forward. SwiftGitX 0.4.0
/// exposes clone/fetch/status but deliberately has no pull API. These calls are
/// limited to graph ancestry, safe checkout, and updating the current branch ref.
private enum NativeGitCRepository {
    static func relationship(at path: URL) throws -> NativeGitRepositoryState.Relationship {
        try withRepository(at: path) { repository in
            guard git_repository_head_detached(repository) != 1 else { return .detached }
            var head: OpaquePointer?
            try check(git_repository_head(&head, repository), operation: "read HEAD")
            guard let head else { throw NativeGitError.notARepository }
            defer { git_reference_free(head) }
            guard git_reference_is_branch(head) == 1 else { return .detached }

            var upstream: OpaquePointer?
            let upstreamStatus = git_branch_upstream(&upstream, head)
            guard upstreamStatus == 0, let upstream else { return .noUpstream }
            defer { git_reference_free(upstream) }

            guard let localPointer = git_reference_target(head),
                  let upstreamPointer = git_reference_target(upstream) else {
                throw NativeGitError.unsupportedRepositoryState("a branch ref does not point to a commit")
            }
            var local = localPointer.pointee
            var remote = upstreamPointer.pointee
            if git_oid_equal(&local, &remote) == 1 { return .upToDate }

            let remoteDescendsFromLocal = git_graph_descendant_of(repository, &remote, &local)
            if remoteDescendsFromLocal < 0 {
                try check(remoteDescendsFromLocal, operation: "compare branch ancestry")
            }
            if remoteDescendsFromLocal == 1 { return .behind }

            let localDescendsFromRemote = git_graph_descendant_of(repository, &local, &remote)
            if localDescendsFromRemote < 0 {
                try check(localDescendsFromRemote, operation: "compare branch ancestry")
            }
            return localDescendsFromRemote == 1 ? .ahead : .diverged
        }
    }

    static func fastForward(at path: URL) throws {
        try withRepository(at: path) { repository in
            guard git_repository_head_detached(repository) != 1 else { throw NativeGitError.detachedHead }
            var head: OpaquePointer?
            try check(git_repository_head(&head, repository), operation: "read HEAD")
            guard let head, git_reference_is_branch(head) == 1 else { throw NativeGitError.detachedHead }
            defer { git_reference_free(head) }

            var upstream: OpaquePointer?
            try check(git_branch_upstream(&upstream, head), operation: "read upstream branch")
            guard let upstream else { throw NativeGitError.missingUpstream }
            defer { git_reference_free(upstream) }

            guard let localPointer = git_reference_target(head),
                  let upstreamPointer = git_reference_target(upstream) else {
                throw NativeGitError.unsupportedRepositoryState("a branch ref does not point to a commit")
            }
            var local = localPointer.pointee
            var remote = upstreamPointer.pointee
            guard git_oid_equal(&local, &remote) != 1 else { return }

            let isFastForward = git_graph_descendant_of(repository, &remote, &local)
            if isFastForward < 0 { try check(isFastForward, operation: "verify fast-forward ancestry") }
            guard isFastForward == 1 else {
                let localIsAhead = git_graph_descendant_of(repository, &local, &remote)
                if localIsAhead < 0 { try check(localIsAhead, operation: "verify fast-forward ancestry") }
                throw localIsAhead == 1 ? NativeGitError.localBranchAhead : NativeGitError.diverged
            }

            var target: OpaquePointer?
            try check(git_object_lookup(&target, repository, &remote, GIT_OBJECT_COMMIT), operation: "load upstream commit")
            guard let target else { throw NativeGitError.notARepository }
            defer { git_object_free(target) }

            var checkoutOptions = git_checkout_options()
            try check(
                git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
                operation: "configure safe checkout"
            )
            checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try check(git_checkout_tree(repository, target, &checkoutOptions), operation: "safe checkout")

            // HEAD remains symbolic to this local branch; moving the branch's ref
            // after its safe checkout is the actual fast-forward. No reset or force
            // flag is used, and the current reference is never retargeted to an
            // unrelated commit because ancestry was proven above.
            var updatedReference: OpaquePointer?
            let updateStatus = git_reference_set_target(
                &updatedReference,
                head,
                &remote,
                "waifuclaw: safe fast-forward"
            )
            defer { if let updatedReference { git_reference_free(updatedReference) } }
            try check(updateStatus, operation: "advance local branch")
        }
    }

    private static func withRepository<T>(at path: URL, body: (OpaquePointer) throws -> T) throws -> T {
        let initialization = git_libgit2_init()
        guard initialization >= 0 else {
            throw NativeGitError.libgit2(operation: "initialize", message: "libgit2 returned \(initialization)")
        }
        defer { _ = git_libgit2_shutdown() }

        var repository: OpaquePointer?
        try check(git_repository_open(&repository, path.path), operation: "open repository")
        guard let repository else { throw NativeGitError.notARepository }
        defer { git_repository_free(repository) }
        return try body(repository)
    }

    private static func check(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            let message: String
            if let error = git_error_last(), let rawMessage = error.pointee.message {
                message = String(cString: rawMessage)
            } else {
                message = "libgit2 returned \(status)"
            }
            throw NativeGitError.libgit2(operation: operation, message: message)
        }
    }
}
