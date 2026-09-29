import Foundation
import LocalAuthentication
import UserNotifications

/// One iOS permission in the first-launch flow.
///
/// Each case carries its explainer-screen copy and the real request path:
/// an explainer is always shown first, then the actual iOS system prompt
/// is summoned via the real API. Nothing here synthesizes permission state.
enum PermissionKind: String, CaseIterable, Identifiable {
    case notifications
    case faceID
    case localNetwork

    var id: String { rawValue }

    // MARK: - Explainer copy

    var title: String {
        switch self {
        case .notifications: "Stay in the loop"
        case .faceID: "Lock it with Face ID"
        case .localNetwork: "Find your computer"
        }
    }

    /// Tier-2 utility icon (contract §11): never a brand moment.
    var systemIcon: String {
        switch self {
        case .notifications: "bell.badge.fill"
        case .faceID: "faceid"
        case .localNetwork: "network"
        }
    }

    var explainer: String {
        switch self {
        case .notifications:
            "WaifuClaw taps you when a run finishes, a review needs your eyes, "
                + "or your agents need a decision. Without this, you'll have to "
                + "open the app to find out anything happened."
        case .faceID:
            "Your API keys and your paired computer deserve a lock. Face ID keeps "
                + "WaifuClaw yours, even if someone picks up your phone."
        case .localNetwork:
            "WaifuClaw finds your desktop over your local network to pair with it. "
                + "iOS asks for this the moment we start looking — that prompt is "
                + "the system talking, not us."
        }
    }

    // MARK: - Honest consequence copy (denied / unavailable)

    var deniedHeading: String {
        switch self {
        case .notifications: "No alerts then"
        case .faceID: "No lock then"
        case .localNetwork: "No auto-discovery then"
        }
    }

    var deniedBody: String {
        switch self {
        case .notifications:
            "You won't get run-finished or review-needed alerts. Everything still "
                + "works — you'll just have to check manually. You can turn these "
                + "on later in the Settings app."
        case .faceID:
            "The app won't lock itself. Anyone holding your unlocked phone can open "
                + "it. You can enable this later in the app's Settings."
        case .localNetwork:
            "Pairing can't auto-discover your computer, so you'll enter its address "
                + "by hand instead. You can allow this later in the iOS Settings app."
        }
    }

    var unavailableBody: String {
        switch self {
        case .faceID:
            "This device can't do Face ID right now — no biometrics are enrolled. "
                + "Continuing without app lock; you can enable it later once Face ID "
                + "is set up in the iOS Settings app."
        default:
            "This permission isn't available on this device right now. Continuing "
                + "without it — nothing else is blocked."
        }
    }

    // MARK: - The real request

    /// Summons the actual iOS system prompt for this permission.
    ///
    /// - Notifications: `UNUserNotificationCenter.requestAuthorization` (native async).
    /// - Face ID: `LAContext.evaluatePolicy` (native async). Requires
    ///   `NSFaceIDUsageDescription` in Info.plist — without it the prompt fails
    ///   and this returns `.unavailable`.
    /// - Local network: iOS exposes no direct request API. Starting a real
    ///   Bonjour browse for `_waifuclaw._tcp` summons the system prompt on
    ///   first use — that browse IS the permission path, and it can genuinely
    ///   discover the desktop while it's at it. Returns `.unknown` because the
    ///   grant itself is unreadable by design; the caller records that we asked.
    ///
    /// `CancellationError` is never swallowed: it propagates to the caller.
    @MainActor
    func request() async throws -> PermissionResult {
        switch self {
        case .notifications:
            return await requestNotifications()
        case .faceID:
            return await requestFaceID()
        case .localNetwork:
            return try await pulseLocalNetwork()
        }
    }

    @MainActor
    private func requestNotifications() async -> PermissionResult {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            return granted ? .granted : .denied
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    @MainActor
    private func requestFaceID() async -> PermissionResult {
        let context = LAContext()
        var evalError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &evalError
        ) else {
            return .unavailable(
                reason: evalError?.localizedDescription
                    ?? "No biometrics are enrolled on this device."
            )
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock WaifuClaw with Face ID"
            )
            return ok ? .granted : .denied
        } catch {
            // User cancelled the prompt, lockout, missing plist key — all land
            // here. Loud, not silent: the caller shows the consequence copy.
            return .denied
        }
    }

    @MainActor
    private func pulseLocalNetwork() async throws -> PermissionResult {
        let browser = DiscoveryBrowser()
        browser.start()
        defer { browser.stop() }
        // Long enough for the system prompt to appear on first browse.
        // Throws CancellationError if the user leaves mid-step — propagated,
        // never mapped to a fake permission state.
        try await Task.sleep(for: .seconds(6))
        return .unknown
    }
}
