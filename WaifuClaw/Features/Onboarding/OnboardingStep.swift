import Foundation

/// Standalone first launch asks only for information the app actually uses.
/// Optional permissions belong beside their working features, not in setup.
enum OnboardingStep: Int, CaseIterable {
    case intro
    case displayName

    var title: String {
        switch self {
        case .intro: "Welcome"
        case .displayName: "Your name"
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    /// 1-based position for the progress header.
    var position: Int { rawValue + 1 }
}
