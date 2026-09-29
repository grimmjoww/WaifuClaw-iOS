import Foundation

/// @AppStorage keys owned by the onboarding flow.
///
/// The onboarding leaf (1.5.2) is the only writer. Other screens — Home's
/// greeting, Settings rows — read these keys; they never write them.
enum OnboardingKeys {
    /// Free-text display name entered on first launch. Never hard-coded.
    static let displayName = "displayName"
    /// Set to true when the first-launch flow completes.
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    /// Whether the push-notification permission was granted.
    static let notificationsGranted = "onboarding.notificationsGranted"
    /// Whether Face ID app lock was enabled.
    static let faceIDEnabled = "onboarding.faceIDEnabled"
    /// Whether the local-network system prompt was shown during setup.
    /// iOS exposes no API to read the actual grant, so this records that
    /// we asked — the real decision lives in the iOS Settings app.
    static let localNetworkRequested = "onboarding.localNetworkRequested"
}
