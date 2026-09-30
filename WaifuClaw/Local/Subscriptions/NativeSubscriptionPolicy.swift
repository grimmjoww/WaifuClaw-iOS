import Foundation

/// Proposed identifiers only. These are not App Store Connect products and this
/// type never supplies a price, a transaction, or access to any feature.
enum NativeSubscriptionProductID: String, CaseIterable, Hashable, Sendable {
    case proMonthly = "studio.phantomhorizons.waifuclaw.pro.monthly"
    case proYearly = "studio.phantomhorizons.waifuclaw.pro.yearly"

    static let allIdentifiers = Set(allCases.map(\.rawValue))

    static func isAllowed(_ productID: String) -> Bool {
        Self(rawValue: productID) != nil
    }
}

/// A dependency-free representation of only the entitlement facts relevant to
/// this app. Keeping it independent of StoreKit makes the access policy
/// deterministic to test and prevents tests from fabricating transactions.
struct NativeSubscriptionEntitlementSnapshot: Equatable, Sendable {
    enum Verification: Equatable, Sendable {
        case verified
        case unverified
    }

    let productID: String
    let verification: Verification
    let revocationDate: Date?
    let expirationDate: Date?

    init(
        productID: String,
        verification: Verification,
        revocationDate: Date? = nil,
        expirationDate: Date? = nil
    ) {
        self.productID = productID
        self.verification = verification
        self.revocationDate = revocationDate
        self.expirationDate = expirationDate
    }
}

enum NativeSubscriptionEntitlementEligibility: Equatable, Sendable {
    case eligible(NativeSubscriptionProductID)
    case unverified
    case productNotAllowed
    case revoked
    case expired
}

enum NativeSubscriptionEntitlement: Equatable, Sendable {
    case free
    case verifiedPro(NativeSubscriptionProductID)

    var productID: NativeSubscriptionProductID? {
        guard case let .verifiedPro(productID) = self else { return nil }
        return productID
    }
}

/// The only policy that can translate verified StoreKit facts into a proposed
/// Pro entitlement. It never reads UserDefaults and is intentionally not wired
/// to any Free feature in this release.
enum NativeSubscriptionEntitlementEvaluator {
    static func eligibility(
        for snapshot: NativeSubscriptionEntitlementSnapshot,
        at date: Date
    ) -> NativeSubscriptionEntitlementEligibility {
        guard snapshot.verification == .verified else { return .unverified }
        guard let productID = NativeSubscriptionProductID(rawValue: snapshot.productID) else {
            return .productNotAllowed
        }
        guard snapshot.revocationDate == nil else { return .revoked }
        if let expirationDate = snapshot.expirationDate, expirationDate <= date {
            return .expired
        }
        return .eligible(productID)
    }

    static func entitlement(
        from snapshots: some Sequence<NativeSubscriptionEntitlementSnapshot>,
        at date: Date
    ) -> NativeSubscriptionEntitlement {
        for snapshot in snapshots {
            if case let .eligible(productID) = eligibility(for: snapshot, at: date) {
                return .verifiedPro(productID)
            }
        }
        return .free
    }
}

/// Shipping is deliberately false for every condition. A future release must
/// explicitly enable all three independently after the Guardian service and
/// App Store products genuinely exist; changing a UI string cannot enable IAP.
struct NativeSubscriptionLaunchConfiguration: Equatable, Sendable {
    let isLaunchEnabled: Bool
    let productsApprovedForSale: Bool
    let guardianServiceReady: Bool

    static let shipping = NativeSubscriptionLaunchConfiguration(
        isLaunchEnabled: false,
        productsApprovedForSale: false,
        guardianServiceReady: false
    )

    var purchasesAreAvailable: Bool {
        isLaunchEnabled && productsApprovedForSale && guardianServiceReady
    }

    var unavailableMessage: String {
        "Pro is not available yet. This release has no paid Guardian service or approved Pro products."
    }
}

/// Local preferences intentionally record only a user's explicit restore tap.
/// They contain no entitlement or `isPro` value: verified StoreKit transactions
/// are the sole source of entitlement truth in `NativeSubscriptionStore`.
struct NativeSubscriptionStorefrontPreferences {
    private enum Key {
        static let lastExplicitRestoreRequestAt = "NativeSubscription.lastExplicitRestoreRequestAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastExplicitRestoreRequestAt: Date? {
        defaults.object(forKey: Key.lastExplicitRestoreRequestAt) as? Date
    }

    func recordExplicitRestoreRequest(at date: Date = .now) {
        defaults.set(date, forKey: Key.lastExplicitRestoreRequestAt)
    }
}
