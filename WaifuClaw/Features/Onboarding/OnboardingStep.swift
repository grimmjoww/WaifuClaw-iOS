import Foundation

/// The first-launch wizard, in the mandated order:
/// intro pages, display name, then the three iOS permission prompts.
enum OnboardingStep: Int, CaseIterable {
    case intro
    case displayName
    case notifications
    case faceID
    case localNetwork

    var title: String {
        switch self {
        case .intro: "Welcome"
        case .displayName: "Your name"
        case .notifications: "Notifications"
        case .faceID: "Face ID"
        case .localNetwork: "Local network"
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    /// 1-based position for the progress header.
    var position: Int { rawValue + 1 }
}
