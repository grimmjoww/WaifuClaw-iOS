import Foundation

/// Sharing an approved fact with a BYOK model is a distinct, per-project
/// permission. The old global beta flag is intentionally not migrated: users
/// must opt in again for each project rather than inheriting broad consent.
struct NativeMemoryConsent {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(for projectID: String?) -> Bool {
        guard let key = Self.key(for: projectID) else { return false }
        return defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool, for projectID: String?) {
        guard let key = Self.key(for: projectID) else { return }
        defaults.set(enabled, forKey: key)
    }

    private static func key(for projectID: String?) -> String? {
        guard let projectID, projectID.count == 64,
              projectID.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else { return nil }
        return "native.memory.shareApproved.\(projectID)"
    }
}
