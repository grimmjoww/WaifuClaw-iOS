import Foundation

/// Local, per-project preference storage for automatic candidate extraction.
///
/// This is intentionally separate from `NativeMemoryConsent`, which controls
/// sending already approved memories to a configured BYOK provider. This store
/// neither reads nor writes that provider-sharing preference.
public struct NativeMemoryAutocapturePreferenceStore {
    private static let keyPrefix = "native.memory.automaticCandidateCapture."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns `.unset` for an unknown, invalid, or never-configured project;
    /// callers must therefore treat automatic candidate extraction as off.
    public func preference(for projectID: String?) -> NativeMemoryAutocapturePreference {
        guard let key = Self.key(for: projectID),
              let rawValue = defaults.string(forKey: key),
              let preference = NativeMemoryAutocapturePreference(rawValue: rawValue)
        else {
            return .unset
        }
        return preference
    }

    /// Persists an affirmative opt-in or explicit opt-out for exactly one
    /// native project. Setting `.unset` clears the project-specific choice.
    /// Invalid project identifiers do not read or mutate `UserDefaults`.
    public func setPreference(_ preference: NativeMemoryAutocapturePreference, for projectID: String?) {
        guard let key = Self.key(for: projectID) else { return }
        switch preference {
        case .unset:
            defaults.removeObject(forKey: key)
        case .optedIn, .optedOut:
            defaults.set(preference.rawValue, forKey: key)
        }
    }

    public func optIn(for projectID: String?) {
        setPreference(.optedIn, for: projectID)
    }

    public func optOut(for projectID: String?) {
        setPreference(.optedOut, for: projectID)
    }

    /// Matches the 64-character lowercase SHA-256 namespace created by
    /// `NativeProjectIdentity`; accepting only that form prevents arbitrary
    /// path-like text from becoming a persistent settings key.
    public static func isValidProjectID(_ projectID: String?) -> Bool {
        guard let projectID, projectID.count == 64 else { return false }
        return projectID.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func key(for projectID: String?) -> String? {
        guard let projectID, isValidProjectID(projectID) else { return nil }
        return keyPrefix + projectID
    }
}
