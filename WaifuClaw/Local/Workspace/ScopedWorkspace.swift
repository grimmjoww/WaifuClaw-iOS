import Foundation

/// A user-selected Files folder is the only project root exposed to the agent.
/// The tools never execute files or follow a symlink outside that root.
struct ScopedWorkspace: Sendable {
    let rootURL: URL
    private let maximumFileBytes = 128 * 1024

    enum WorkspaceError: LocalizedError {
        case invalidFolder
        case invalidPath
        case deniedPath
        case notAFile
        case fileTooLarge
        case notText

        var errorDescription: String? {
            switch self {
            case .invalidFolder: "Select a readable project folder in Files."
            case .invalidPath: "Use a relative path inside the selected project."
            case .deniedPath: "This path is outside the selected project or contains private project metadata."
            case .notAFile: "The requested path is not a regular file."
            case .fileTooLarge: "This file exceeds the agent's 128 KB read limit."
            case .notText: "The agent only reads UTF-8 text files."
            }
        }
    }

    init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw WorkspaceError.invalidFolder }
        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer { if accessing { rootURL.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WorkspaceError.invalidFolder }
        self.rootURL = rootURL
    }

    func listFiles(relativePath: String = ".") throws -> [String] {
        try withAccess {
            let folder = try resolvedURL(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw WorkspaceError.invalidFolder }
            let entries = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return entries
                .filter { !Self.isSensitive($0.lastPathComponent) }
                .prefix(100)
                .map { entry in
                    let relative = entry.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                    let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return relative + (isFolder ? "/" : "")
                }
                .sorted()
        }
    }

    func readFile(relativePath: String) throws -> String {
        try withAccess {
            let url = try resolvedURL(relativePath)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw WorkspaceError.notAFile }
            guard (values.fileSize ?? 0) <= maximumFileBytes else { throw WorkspaceError.fileTooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard data.count <= maximumFileBytes else { throw WorkspaceError.fileTooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.notText }
            return text
        }
    }

    private func resolvedURL(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !trimmed.split(separator: "/").contains(".."),
              !trimmed.split(separator: "/").contains(where: { Self.isSensitive(String($0)) })
        else { throw WorkspaceError.invalidPath }
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == canonicalRoot.path ||
              candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw WorkspaceError.deniedPath
        }
        return candidate
    }

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer { if accessing { rootURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private static func isSensitive(_ component: String) -> Bool {
        let lowered = component.lowercased()
        return lowered == ".git" || lowered == ".env" || lowered.hasPrefix(".env.") ||
            lowered == "id_rsa" || lowered == "id_ed25519" || lowered == "credentials.json"
    }
}
