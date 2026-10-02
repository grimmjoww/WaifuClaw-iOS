import Foundation

/// iOS has no blanket "filesystem" permission. The document picker returns a
/// single user-chosen folder with a revocable security-scoped bookmark. This
/// service owns that app-level selection; file tools still validate every path.
struct NativeProjectPermission {
    static let bookmarkKey = "native.workspace.folderBookmark"

    enum PermissionError: LocalizedError {
        case staleBookmark

        var errorDescription: String? {
            switch self {
            case .staleBookmark:
                "The Files folder grant is stale. Select that folder again to continue."
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedFolder() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw PermissionError.staleBookmark }
        _ = try ScopedWorkspace(rootURL: url)
        return url
    }

    @discardableResult
    func selectFolder(_ url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        _ = try ScopedWorkspace(rootURL: url)
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return url.lastPathComponent
    }

    func disconnectFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }
}
