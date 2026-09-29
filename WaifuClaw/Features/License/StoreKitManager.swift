import Foundation
import StoreKit

/// StoreKit 2 wrapper for Pro subscriptions. Every state is visible:
/// loading products, purchasing, pending (Ask to Buy), verified, failed,
/// receipt-verification failure, and restore — per the product-law checklist.
/// Product IDs are placeholders until App Store Connect is configured —
/// see CONTRACT_DRIFT.md.
@MainActor
final class StoreKitManager: ObservableObject {
    static let proMonthlyID = "studio.phantomhorizons.waifuclaw.pro.monthly"
    static let proYearlyID = "studio.phantomhorizons.waifuclaw.pro.yearly"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let isError: Bool
        let message: String
    }

    @Published var products: [Product] = []
    @Published var loadState: LoadState = .idle
    @Published var purchasingProductID: String?
    @Published var restoring = false
    @Published var notice: Notice?

    /// Called with "<productID>:<transactionID>" for every VERIFIED purchase
    /// (fresh, restored, or arriving via Transaction.updates). The view links
    /// it to the desktop license and posts the user-facing notice itself.
    var onVerifiedPurchase: ((String) async -> Void)?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let fetched = try await Product.products(for: [Self.proMonthlyID, Self.proYearlyID])
            products = fetched.sorted { $0.price < $1.price }
            loadState = .loaded
        } catch {
            loadState = .failed("Couldn't load purchase options — check your connection and try again.")
        }
    }

    func purchase(_ product: Product) async {
        guard purchasingProductID == nil else { return }
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await onVerifiedPurchase?("\(product.id):\(transaction.id)")
                case .unverified:
                    // Receipt-validation failure — loud, and no charge happened.
                    notice = Notice(
                        isError: true,
                        message: "Apple couldn't verify that purchase, so it was cancelled. You were not charged — please try again."
                    )
                }
            case .userCancelled:
                break // deliberate, stays silent
            case .pending:
                notice = Notice(
                    isError: false,
                    message: "Purchase is pending approval (for example Ask to Buy). It will finish on its own — nothing else to do."
                )
            @unknown default:
                break
            }
        } catch {
            notice = Notice(isError: true, message: "Purchase failed: \(error.localizedDescription)")
        }
    }

    func restorePurchases() async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        var found = false
        do {
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      [Self.proMonthlyID, Self.proYearlyID].contains(transaction.productID)
                else { continue }
                found = true
                await onVerifiedPurchase?("\(transaction.productID):\(transaction.id)")
            }
        } catch {
            notice = Notice(isError: true, message: "Restore failed: \(error.localizedDescription)")
            return
        }
        if !found {
            notice = Notice(isError: false, message: "No previous Pro purchases found on this Apple ID.")
        }
    }

    /// Purchases that finish outside this screen (another device, a pending
    /// Ask-to-Buy approval). Verified only; unverified results are ignored
    /// here and surfaced if the user retries the purchase directly.
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result,
                  [Self.proMonthlyID, Self.proYearlyID].contains(transaction.productID)
            else { continue }
            await transaction.finish()
            await onVerifiedPurchase?("\(transaction.productID):\(transaction.id)")
        }
    }
}
