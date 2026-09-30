import StoreKit
import SwiftUI

/// A storefront shell for a future Pro launch. With the shipping launch
/// configuration, this deliberately contains no purchasable plan, price, or
/// Restore Purchases action: there is no paid Guardian service to sell yet.
struct NativeSubscriptionStorefrontView: View {
    @State private var store: NativeSubscriptionStore

    init(store: NativeSubscriptionStore = NativeSubscriptionStore()) {
        _store = State(initialValue: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingL) {
                heroCard

                if store.purchasesAreAvailable {
                    liveStorefront
                } else {
                    unavailableCard
                }
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Pro")
        .task { await store.start() }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Label("WaifuClaw Pro", systemImage: "sparkles")
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)
            Text("Optional paid membership")
                .font(Theme.headline)
                .foregroundStyle(Theme.magentaSoft)
            Text("Free features remain available without Pro. A paid plan will only be offered when its ongoing Guardian service and App Store products are actually ready.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Label("Not available", systemImage: "pause.circle.fill")
                .font(Theme.headline)
                .foregroundStyle(Theme.warning)
            Text(store.configuration.unavailableMessage)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Text("There is no price or checkout in this release. Nothing on this screen can charge your Apple Account.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Purchases are not available")
                .font(Theme.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(Theme.textSecondary)
                .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        }
        .themeCard()
    }

    @ViewBuilder
    private var liveStorefront: some View {
        switch store.storefrontState {
        case .notAvailable:
            unavailableCard
        case .notStarted, .loadingProducts:
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                ProgressView()
                    .tint(Theme.magenta)
                Text("Loading available Pro options from the App Store…")
                    .foregroundStyle(Theme.textSecondary)
            }
            .themeCard()
        case .productsMissing:
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                Label("Not available", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.warning)
                Text("The App Store has not returned every required Pro product. Purchases remain unavailable.")
                    .foregroundStyle(Theme.textSecondary)
            }
            .themeCard()
        case let .failed(message):
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                Label("Store unavailable", systemImage: "wifi.exclamationmark")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Try again") {
                    Task { await store.fetchProducts() }
                }
                .buttonStyle(.bordered)
            }
            .themeCard()
        case .ready:
            liveProductList
        }
    }

    private var liveProductList: some View {
        VStack(alignment: .leading, spacing: Theme.spacingL) {
            ForEach(store.products, id: \.id) { product in
                VStack(alignment: .leading, spacing: Theme.spacingS) {
                    Text(product.displayName)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(product.description)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                    // This value comes directly from StoreKit. No product or
                    // price is represented until the App Store supplies it.
                    Text(product.displayPrice)
                        .font(Theme.title.bold())
                        .foregroundStyle(Theme.magentaSoft)
                    Button(store.isPurchasing ? "Purchasing…" : "Continue") {
                        Task { await store.purchase(productID: product.id) }
                    }
                    .themePrimaryButton()
                    .disabled(!store.canStartPurchase)
                }
                .themeCard()
            }

            restoreCard
            statusCard
        }
    }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("Already purchased?")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Restore Purchases contacts the App Store only after you tap it. It may ask you to authenticate.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            Button(store.isRestoring ? "Restoring…" : "Restore purchases") {
                // This is the sole UI call site for AppStore.sync(). The store
                // never synchronizes automatically on launch or refresh.
                Task { await store.restorePurchases() }
            }
            .buttonStyle(.bordered)
            .disabled(store.isPurchasing || store.isRestoring)
        }
        .themeCard()
    }

    @ViewBuilder
    private var statusCard: some View {
        if let message = storefrontStatusMessage {
            Label(message, systemImage: storefrontStatusSymbol)
                .font(Theme.caption)
                .foregroundStyle(storefrontStatusColor)
                .themeCard()
        }
    }

    private var storefrontStatusMessage: String? {
        if let outcome = store.lastPurchaseOutcome {
            switch outcome {
            case .notAvailable:
                return "Purchases are not available."
            case .productNotAllowed:
                return "That product is not a supported Pro plan."
            case .productNotLoaded:
                return "That product is not currently available from the App Store."
            case .purchaseAlreadyInProgress:
                return "Another StoreKit action is already in progress."
            case .paymentsUnavailable:
                return "This Apple Account cannot make purchases right now."
            case .completed:
                return "Purchase completed. Verified entitlement information has been refreshed."
            case .pending:
                return "Purchase is pending approval. No Pro entitlement is active yet."
            case .cancelled:
                return "Purchase cancelled."
            case .unverified:
                return "The purchase could not be verified and was not used."
            case let .failed(message):
                return "Purchase failed: \(message)"
            }
        }

        if let outcome = store.lastRestoreOutcome {
            switch outcome {
            case .notAvailable:
                return "Restoring purchases is not available."
            case .restoreAlreadyInProgress:
                return "Another StoreKit action is already in progress."
            case .restoredVerifiedEntitlement:
                return "A verified Pro entitlement was restored."
            case .completedWithNoEntitlement:
                return "Restore completed. No active verified Pro entitlement was found."
            case let .failed(message):
                return "Restore failed: \(message)"
            }
        }

        if let productID = store.entitlement.productID {
            return "Verified Pro entitlement: \(productID.rawValue)"
        }
        return store.verificationNotice
    }

    private var storefrontStatusSymbol: String {
        if store.entitlement.productID != nil { return "checkmark.seal.fill" }
        return "exclamationmark.shield.fill"
    }

    private var storefrontStatusColor: Color {
        if store.entitlement.productID != nil { return Theme.success }
        return Theme.warning
    }
}
