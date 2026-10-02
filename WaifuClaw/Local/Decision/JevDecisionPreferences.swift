import Foundation

/// Non-secret preference for optional Jev routing assessments. It is false when
/// absent, so adding Jev support never enables a provider call by default.
struct JevDecisionPreferences {
    static let decisionOptInKey = "native.jev.decisionOptIn"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDecisionOptedIn: Bool {
        get {
            // `bool(forKey:)` also defaults to false, but checking the object
            // makes the off-by-default behavior explicit and testable.
            (defaults.object(forKey: Self.decisionOptInKey) as? Bool) ?? false
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.decisionOptInKey)
        }
    }
}
