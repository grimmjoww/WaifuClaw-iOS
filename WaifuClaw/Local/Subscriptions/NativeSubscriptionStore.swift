import Foundation
import Observation
import StoreKit

/// UI-facing state for the real StoreKit catalog. No state in this enum grants
/// access; only `NativeSubscriptionEntitlementEvaluator` can do that.
enum NativeSubscriptionStorefrontState: Equatable {
    case notAvailable
    case notStarted
    case loadingProducts
    case ready
    case productsMissing
    case failed(String)
}

enum NativeSubscriptionPurchaseOutcome: Equatable {
    case notAvailable
    case productNotAllowed
    case productNotLoaded
    case purchaseAlreadyInProgress
    case paymentsUnavailable
    case completed
    case pending
    case cancelled
    case unverified
    case failed(String)
}

enum NativeSubscriptionRestoreOutcome: Equatable {
    case notAvailable
    case restoreAlreadyInProgress
    case restoredVerifiedEntitlement
    case completedWithNoEntitlement
    case failed(String)
}

/// StoreKit 2 boundary for proposed Pro subscriptions.
///
/// The app ships with `NativeSubscriptionLaunchConfiguration.shipping`, so it
/// neither presents a purchase path nor calls `Product.purchase()` or
/// `AppStore.sync()`. StoreKit entitlements are nevertheless evaluated from
/// verified transactions only, never from a locally cached Boolean.
///
/// Apple documentation:
/// - https://developer.apple.com/documentation/storekit/transaction/currententitlements
/// - https://developer.apple.com/documentation/storekit/appstore/sync()
@Observable
@MainActor
final class NativeSubscriptionStore {
    let configuration: NativeSubscriptionLaunchConfiguration

    private(set) var storefrontState: NativeSubscriptionStorefrontState
    private(set) var products: [Product] = []
    private(set) var entitlement: NativeSubscriptionEntitlement = .free
    private(set) var verificationNotice: String?
    private(set) var lastPurchaseOutcome: NativeSubscriptionPurchaseOutcome?
    private(set) var lastRestoreOutcome: NativeSubscriptionRestoreOutcome?
    private(set) var isPurchasing = false
    private(set) var isRestoring = false

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private let preferences: NativeSubscriptionStorefrontPreferences

    init(
        configuration: NativeSubscriptionLaunchConfiguration = .shipping,
        preferences: NativeSubscriptionStorefrontPreferences = NativeSubscriptionStorefrontPreferences()
    ) {
        self.configuration = configuration
        self.preferences = preferences
        self.storefrontState = configuration.purchasesAreAvailable ? .notStarted : .notAvailable
    }

    var purchasesAreAvailable: Bool {
        configuration.purchasesAreAvailable
    }

    var canStartPurchase: Bool {
        purchasesAreAvailable && !isPurchasing && !isRestoring
    }

    /// Starts listening before loading current entitlement state. Call this once
    /// from the app's retained root store; repeated calls are harmless.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard configuration.purchasesAreAvailable else {
            storefrontState = .notAvailable
            return
        }
        observeTransactionUpdates()
        await refreshCurrentEntitlements()
        await fetchProducts()
    }

    func stop() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = nil
        hasStarted = false
    }

    /// Requests only the fixed allowlist from the App Store. The actual
    /// `Product.displayPrice` is never invented; it is available to the UI only
    /// after StoreKit returns a genuine product and launch requirements are on.
    func fetchProducts() async {
        guard configuration.purchasesAreAvailable else {
            products = []
            storefrontState = .notAvailable
            return
        }

        storefrontState = .loadingProducts
        do {
            let fetchedProducts = try await Product.products(for: Array(NativeSubscriptionProductID.allIdentifiers).sorted())
            var productsByIdentifier: [String: Product] = [:]
            for product in fetchedProducts where NativeSubscriptionProductID.isAllowed(product.id) {
                // Keep the response deterministic without assuming StoreKit
                // cannot ever return a duplicate identifier.
                productsByIdentifier[product.id] = product
            }
            products = NativeSubscriptionProductID.allCases.compactMap {
                productsByIdentifier[$0.rawValue]
            }

            let foundIdentifiers = Set(products.map(\.id))
            storefrontState = foundIdentifiers == NativeSubscriptionProductID.allIdentifiers
                ? .ready
                : .productsMissing
        } catch {
            products = []
            storefrontState = .failed(error.localizedDescription)
        }
    }

    /// Rebuilds access from the App Store's current entitlement sequence. An
    /// unverified result is deliberately omitted and never turns into Pro.
    func refreshCurrentEntitlements() async {
        var snapshots: [NativeSubscriptionEntitlementSnapshot] = []
        var receivedUnverifiedResult = false

        for await result in Transaction.currentEntitlements {
            switch result {
            case let .verified(transaction):
                snapshots.append(snapshot(from: transaction, verification: .verified))
            case .unverified:
                receivedUnverifiedResult = true
            }
        }

        entitlement = NativeSubscriptionEntitlementEvaluator.entitlement(from: snapshots, at: .now)
        verificationNotice = receivedUnverifiedResult
            ? "A StoreKit transaction could not be verified and was not used."
            : nil
    }

    /// Initiates a StoreKit purchase only after every launch/service/product
    /// prerequisite is enabled. A disabled release cannot reach StoreKit's
    /// purchase confirmation sheet through this method.
    @discardableResult
    func purchase(productID: String) async -> NativeSubscriptionPurchaseOutcome {
        guard configuration.purchasesAreAvailable else { return record(.notAvailable) }
        guard NativeSubscriptionProductID.isAllowed(productID) else { return record(.productNotAllowed) }
        guard let product = products.first(where: { $0.id == productID }) else {
            return record(.productNotLoaded)
        }
        guard !isPurchasing, !isRestoring else { return record(.purchaseAlreadyInProgress) }
        guard AppStore.canMakePayments else { return record(.paymentsUnavailable) }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case let .success(result):
                switch result {
                case let .verified(transaction):
                    // Product IDs are checked again at the transaction boundary
                    // before the new state is read. A verified non-Pro
                    // transaction is finished but never grants Pro access.
                    guard NativeSubscriptionProductID.isAllowed(transaction.productID) else {
                        await transaction.finish()
                        return record(.productNotAllowed)
                    }
                    await transaction.finish()
                    await refreshCurrentEntitlements()
                    return record(.completed)
                case .unverified:
                    verificationNotice = "A StoreKit purchase could not be verified and was not used."
                    return record(.unverified)
                }
            case .pending:
                return record(.pending)
            case .userCancelled:
                return record(.cancelled)
            @unknown default:
                return record(.failed("StoreKit returned an unsupported purchase result."))
            }
        } catch {
            return record(.failed(error.localizedDescription))
        }
    }

    /// Call only from a visible, explicit Restore Purchases tap. This is never
    /// invoked by `start()` or automatic refresh. Apple notes that `sync()` can
    /// prompt for App Store credentials, so routine app startup must not call it.
    @discardableResult
    func restorePurchases() async -> NativeSubscriptionRestoreOutcome {
        guard configuration.purchasesAreAvailable else { return recordRestore(.notAvailable) }
        guard !isRestoring, !isPurchasing else { return recordRestore(.restoreAlreadyInProgress) }

        isRestoring = true
        preferences.recordExplicitRestoreRequest()
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshCurrentEntitlements()
            switch entitlement {
            case .verifiedPro:
                return recordRestore(.restoredVerifiedEntitlement)
            case .free:
                return recordRestore(.completedWithNoEntitlement)
            }
        } catch {
            return recordRestore(.failed(error.localizedDescription))
        }
    }

    private func observeTransactionUpdates() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        switch result {
        case let .verified(transaction):
            // Finish verified transactions even when their product isn't one of
            // ours, so StoreKit does not redeliver it. The allowlist still
            // prevents it from affecting this app's Pro state.
            await transaction.finish()
            await refreshCurrentEntitlements()
        case .unverified:
            verificationNotice = "A StoreKit transaction update could not be verified and was not used."
            await refreshCurrentEntitlements()
        }
    }

    private func snapshot(
        from transaction: Transaction,
        verification: NativeSubscriptionEntitlementSnapshot.Verification
    ) -> NativeSubscriptionEntitlementSnapshot {
        NativeSubscriptionEntitlementSnapshot(
            productID: transaction.productID,
            verification: verification,
            revocationDate: transaction.revocationDate,
            expirationDate: transaction.expirationDate
        )
    }

    private func record(_ outcome: NativeSubscriptionPurchaseOutcome) -> NativeSubscriptionPurchaseOutcome {
        lastPurchaseOutcome = outcome
        return outcome
    }

    private func recordRestore(_ outcome: NativeSubscriptionRestoreOutcome) -> NativeSubscriptionRestoreOutcome {
        lastRestoreOutcome = outcome
        return outcome
    }
}
