import CryptoKit
import Foundation

/// Metadata for a visible item in the user-selected workspace folder.
struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
    }

    let relativePath: String
    let name: String
    let kind: Kind

    var id: String { relativePath }
    var isFolder: Bool { kind == .folder }
}

/// A bounded, real directory listing. When truncated, every returned entry is
/// real, but Files may contain more than the displayed safety limit.
struct WorkspaceDirectory: Sendable {
    let relativePath: String
    let entries: [WorkspaceEntry]
    let isTruncated: Bool
}

/// A UTF-8 text file snapshot. Its digest is the exact on-disk content that
/// was opened, and is used to prevent overwriting a concurrent Files change.
struct WorkspaceTextDocument: Sendable {
    let relativePath: String
    let originalText: String
    let originalSHA256: String

    fileprivate init(relativePath: String, data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceEditorError.notUTF8
        }
        self.relativePath = relativePath
        self.originalText = text
        self.originalSHA256 = WorkspaceEditor.sha256(data)
    }
}

/// Retains only the bytes needed to reverse the most recent explicit Save.
/// It is deliberately in-memory only: undo is never performed autonomously
/// after a relaunch.
struct WorkspaceUndoRecord: Sendable {
    let relativePath: String
    fileprivate let originalData: Data
    fileprivate let originalSHA256: String
    fileprivate let savedSHA256: String
}

struct WorkspaceSaveResult: Sendable {
    let document: WorkspaceTextDocument
    let undoRecord: WorkspaceUndoRecord
}

enum WorkspaceEditorError: LocalizedError, Equatable {
    case invalidFolder
    case invalidPath
    case outsideRoot
    case sensitivePath
    case notDirectory
    case notFile
    case fileTooLarge
    case notUTF8
    case concurrentModification
    case coordinationFailed

    var errorDescription: String? {
        switch self {
        case .invalidFolder:
            return "Choose a readable folder in Files."
        case .invalidPath:
            return "This path is not a valid relative path in the selected folder."
        case .outsideRoot:
            return "This item resolves outside the selected folder and was blocked."
        case .sensitivePath:
            return "This item is hidden because it may contain repository metadata or credentials."
        case .notDirectory:
            return "This item is not a folder."
        case .notFile:
            return "This item is not a regular file."
        case .fileTooLarge:
            return "Only UTF-8 text files up to 128 KB can be opened or saved here."
        case .notUTF8:
            return "This file is not UTF-8 text and cannot be edited."
        case .concurrentModification:
            return "This file changed in Files after it was opened. Reload it before saving or undoing."
        case .coordinationFailed:
            return "Files could not coordinate this change. Try again after closing the file elsewhere."
        }
    }
}

/// Performs narrowly scoped, user-initiated workspace reads and writes.
///
/// Every public I/O method starts and stops access to the selected folder.
/// Relative paths are rejected before filesystem access if they contain `..`,
/// an absolute path, a sensitive component, or an escaping symlink target.
struct WorkspaceEditor: Sendable {
    static let maximumTextBytes = 128 * 1024
    static let maximumEntriesPerDirectory = 500

    private let rootURL: URL
    private let canonicalRootURL: URL

    init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw WorkspaceEditorError.invalidFolder }

        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { rootURL.stopAccessingSecurityScopedResource() }
        }

        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonicalRoot.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw WorkspaceEditorError.invalidFolder }

        self.rootURL = rootURL
        self.canonicalRootURL = canonicalRoot
    }

    /// Lists direct children of one permitted directory; it never recurses.
    func listDirectory(relativePath: String = "") throws -> WorkspaceDirectory {
        try withSecurityScopedAccess {
            let folder = try resolvedURL(relativePath, allowsRoot: true)
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw WorkspaceEditorError.notDirectory }

            let children = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )

            var entries: [WorkspaceEntry] = []
            for child in children {
                let name = child.lastPathComponent
                guard !Self.isSensitiveComponent(name) else { continue }

                let childPath = relativePath.isEmpty || relativePath == "."
                    ? name
                    : relativePath + "/" + name
                // Resolve every listing child before displaying it. A symlink
                // that points out of the root is neither browsed nor revealed.
                guard let safeChild = try? resolvedURL(childPath, allowsRoot: false) else { continue }
                guard let childValues = try? safeChild.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                    continue
                }

                if childValues.isDirectory == true {
                    entries.append(WorkspaceEntry(relativePath: childPath, name: name, kind: .folder))
                } else if childValues.isRegularFile == true {
                    entries.append(WorkspaceEntry(relativePath: childPath, name: name, kind: .file))
                }
            }

            let ordered = entries.sorted {
                if $0.kind != $1.kind { return $0.isFolder && !$1.isFolder }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let limited = Array(ordered.prefix(Self.maximumEntriesPerDirectory))
            return WorkspaceDirectory(
                relativePath: relativePath == "." ? "" : relativePath,
                entries: limited,
                isTruncated: ordered.count > limited.count
            )
        }
    }

    /// Opens an existing regular file as bounded UTF-8 text.
    func readText(relativePath: String) throws -> WorkspaceTextDocument {
        try withSecurityScopedAccess {
            let url = try resolvedURL(relativePath, allowsRoot: false)
            let data = try boundedFileData(at: url)
            return try WorkspaceTextDocument(relativePath: relativePath, data: data)
        }
    }

    /// Saves only an explicit user draft. The hash check happens inside a Files
    /// write coordination block, before any data is replaced.
    func save(document: WorkspaceTextDocument, draft: String) throws -> WorkspaceSaveResult {
        let draftData = Data(draft.utf8)
        guard draftData.count <= Self.maximumTextBytes else { throw WorkspaceEditorError.fileTooLarge }

        return try withSecurityScopedAccess {
            let target = try resolvedURL(document.relativePath, allowsRoot: false)
            let savedHash = Self.sha256(draftData)
            let originalData = try coordinatedWrite(at: target) { coordinatedURL in
                let currentURL = coordinatedURL.standardizedFileURL.resolvingSymlinksInPath()
                guard Self.isInside(currentURL, root: canonicalRootURL) else {
                    throw WorkspaceEditorError.outsideRoot
                }
                let currentData = try boundedFileData(at: currentURL)
                guard Self.sha256(currentData) == document.originalSHA256 else {
                    throw WorkspaceEditorError.concurrentModification
                }
                try draftData.write(to: currentURL, options: .atomic)
                return currentData
            }

            let updated = try WorkspaceTextDocument(relativePath: document.relativePath, data: draftData)
            let undo = WorkspaceUndoRecord(
                relativePath: document.relativePath,
                originalData: originalData,
                originalSHA256: document.originalSHA256,
                savedSHA256: savedHash
            )
            return WorkspaceSaveResult(document: updated, undoRecord: undo)
        }
    }

    /// Reverts the most recent explicit save only if the saved content is still
    /// present. A changed or replaced file is never overwritten by undo.
    func undoLastSave(_ undoRecord: WorkspaceUndoRecord) throws -> WorkspaceTextDocument {
        guard Self.sha256(undoRecord.originalData) == undoRecord.originalSHA256 else {
            throw WorkspaceEditorError.coordinationFailed
        }
        return try withSecurityScopedAccess {
            let target = try resolvedURL(undoRecord.relativePath, allowsRoot: false)
            try coordinatedWrite(at: target) { coordinatedURL in
                let currentURL = coordinatedURL.standardizedFileURL.resolvingSymlinksInPath()
                guard Self.isInside(currentURL, root: canonicalRootURL) else {
                    throw WorkspaceEditorError.outsideRoot
                }
                let currentData = try boundedFileData(at: currentURL)
                guard Self.sha256(currentData) == undoRecord.savedSHA256 else {
                    throw WorkspaceEditorError.concurrentModification
                }
                try undoRecord.originalData.write(to: currentURL, options: .atomic)
            }
            return try WorkspaceTextDocument(relativePath: undoRecord.relativePath, data: undoRecord.originalData)
        }
    }

    private func withSecurityScopedAccess<T>(_ operation: () throws -> T) throws -> T {
        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { rootURL.stopAccessingSecurityScopedResource() }
        }
        return try operation()
    }

    private func resolvedURL(_ relativePath: String, allowsRoot: Bool) throws -> URL {
        let components = try Self.validatedComponents(relativePath, allowsRoot: allowsRoot)
        let candidate = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isInside(canonicalCandidate, root: canonicalRootURL) else {
            throw WorkspaceEditorError.outsideRoot
        }
        return canonicalCandidate
    }

    private func boundedFileData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceEditorError.notFile }
        guard (values.fileSize ?? 0) <= Self.maximumTextBytes else {
            throw WorkspaceEditorError.fileTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumTextBytes + 1) ?? Data()
        guard data.count <= Self.maximumTextBytes else { throw WorkspaceEditorError.fileTooLarge }
        return data
    }

    private func coordinatedWrite<T>(at url: URL, operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationResult: Result<T, Error>?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                operationResult = .success(try operation(coordinatedURL))
            } catch {
                operationResult = .failure(error)
            }
        }

        if coordinationError != nil { throw WorkspaceEditorError.coordinationFailed }
        guard let operationResult else { throw WorkspaceEditorError.coordinationFailed }
        return try operationResult.get()
    }

    private static func validatedComponents(_ path: String, allowsRoot: Bool) throws -> [String] {
        if (path.isEmpty || path == ".") && allowsRoot { return [] }
        guard !path.isEmpty,
              path != ".",
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\")
        else { throw WorkspaceEditorError.invalidPath }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw WorkspaceEditorError.invalidPath }
        guard !components.contains(where: isSensitiveComponent) else {
            throw WorkspaceEditorError.sensitivePath
        }
        return components
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSensitiveComponent(_ component: String) -> Bool {
        let name = component.lowercased()
        if name == ".git" || name == ".env" || name.hasPrefix(".env.") {
            return true
        }
        if [".aws", ".ssh", ".gnupg", ".netrc", "credentials", "credentials.json",
            "credential.json", "secret", "secret.json", "secrets", "secrets.json",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "authorized_keys"].contains(name) {
            return true
        }
        let extensionName = URL(fileURLWithPath: name).pathExtension
        return ["pem", "key", "p12", "pfx", "mobileprovision"].contains(extensionName)
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A small, bounded line diff for the editor preview. It uses an LCS matrix
/// only over the first 240 lines of each version, avoiding unbounded UI work.
enum WorkspaceLineDiff {
    enum Kind {
        case context
        case removed
        case added
        case notice
    }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    static func make(original: String, draft: String, limit: Int = 240) -> [Line] {
        guard original != draft else { return [] }

        let originalLines = lines(in: original)
        let draftLines = lines(in: draft)
        let originalPrefix = Array(originalLines.prefix(limit))
        let draftPrefix = Array(draftLines.prefix(limit))
        let wasTruncated = originalPrefix.count < originalLines.count || draftPrefix.count < draftLines.count

        let width = draftPrefix.count + 1
        var lcs = Array(repeating: 0, count: (originalPrefix.count + 1) * width)
        if !originalPrefix.isEmpty && !draftPrefix.isEmpty {
            for oldIndex in stride(from: originalPrefix.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: draftPrefix.count - 1, through: 0, by: -1) {
                    let index = oldIndex * width + newIndex
                    if originalPrefix[oldIndex] == draftPrefix[newIndex] {
                        lcs[index] = lcs[(oldIndex + 1) * width + newIndex + 1] + 1
                    } else {
                        lcs[index] = max(lcs[(oldIndex + 1) * width + newIndex], lcs[oldIndex * width + newIndex + 1])
                    }
                }
            }
        }

        var output: [(Kind, String)] = []
        if wasTruncated {
            output.append((.notice, "Diff preview is limited to the first \(limit) lines of each version."))
        }

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < originalPrefix.count && newIndex < draftPrefix.count {
            if originalPrefix[oldIndex] == draftPrefix[newIndex] {
                output.append((.context, originalPrefix[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if lcs[(oldIndex + 1) * width + newIndex] >= lcs[oldIndex * width + newIndex + 1] {
                output.append((.removed, originalPrefix[oldIndex]))
                oldIndex += 1
            } else {
                output.append((.added, draftPrefix[newIndex]))
                newIndex += 1
            }
        }
        while oldIndex < originalPrefix.count {
            output.append((.removed, originalPrefix[oldIndex]))
            oldIndex += 1
        }
        while newIndex < draftPrefix.count {
            output.append((.added, draftPrefix[newIndex]))
            newIndex += 1
        }

        return output.enumerated().map { Line(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
