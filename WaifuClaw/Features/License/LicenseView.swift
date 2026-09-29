import SwiftUI

/// Pro tab: license status badge, WC1- key activation with inline validation,
/// and StoreKit subscriptions. Purchase, failure, receipt-validation failure,
/// and restore all have visible feedback (product-law checklist).
struct LicenseView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = StoreKitManager()

    @State private var keyInput = ""
    @State private var keyPhase: KeyPhase = .idle

    enum KeyPhase: Equatable {
        case idle
        case activating
        case error(String)
        case success
    }

    private var license: LicenseStatus? { appState.license }

    /// Inline WC1- validation (product-law example) — before any network call.
    private var keyHint: String? {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return nil }
        if !key.hasPrefix("WC1-") { return "Keys start with WC1-." }
        if key.count < 12 { return "That looks too short — make sure you pasted the whole key." }
        return nil
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    if let notice = store.notice {
                        NoticeBanner(notice: notice) { store.notice = nil }
                    }
                    statusCard
                    keyCard
                    iapCard
                    Text("Subscriptions are billed by Apple and can be managed in iPhone Settings → Apple ID → Subscriptions.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .refreshable { await refreshLicense() }
        }
        .navigationTitle("Pro")
        .task {
            store.onVerifiedPurchase = { await linkPurchase($0) }
            await store.loadProducts()
            await refreshLicense()
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WaifuClaw Pro")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                TierBadge(isPro: license?.isPro ?? false)
            }
            if let expiry = expiryText {
                Text(expiry)
                    .font(.subheadline)
                    .foregroundStyle(license?.isPro == true && (license?.daysUntilExpiry ?? 1) < 0
                        ? Theme.warning : Theme.textSecondary)
            }
            if let message = license?.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let used = license?.devices_used, let limit = license?.device_limit {
                Text("\(used) of \(limit) devices used")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let features = license?.features, !features.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
            if license == nil {
                Text("Couldn't load your license status — pull to refresh.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .themeCard()
    }

    private var expiryText: String? {
        guard let license else { return nil }
        guard let days = license.daysUntilExpiry, let date = license.expiryDate else {
            return license.isPro ? "Active — no expiry set." : "Free tier."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        if days < 0 {
            return "Expired \(formatter.string(from: date)) — renew to keep Pro."
        } else if days == 0 {
            return "Expires today."
        }
        return "Renews \(formatter.string(from: date)) (\(days) days)."
    }

    // MARK: - Key activation

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Have a license key?")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            TextField("WC1-XXXX-…", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            if let hint = keyHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            switch keyPhase {
            case .idle:
                EmptyView()
            case .activating:
                ProgressView().tint(Theme.magenta)
            case .error(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            case .success:
                Label("Pro activated — enjoy!", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
            }
            Button("Activate key") { activate() }
                .themePrimaryButton()
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || keyHint != nil || keyPhase == .activating)
        }
        .themeCard()
    }

    private func activate() {
        guard let api = appState.api else { return }
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyHint == nil, !key.isEmpty else { return }
        keyPhase = .activating
        Task {
            do {
                // The response body shape varies; EmptyResponse tolerates any
                // JSON object — the status refresh below is the source of truth.
                let _: EmptyResponse = try await api.post(
                    Endpoints.Remote.licenseActivate,
                    body: LicenseActivateRequest(key: key)
                )
                await refreshLicense()
                if appState.license?.isPro == true {
                    keyPhase = .success
                    keyInput = ""
                } else {
                    keyPhase = .error("That key didn't activate Pro — check the key and try again.")
                }
            } catch let apiError as APIError {
                keyPhase = .error(apiError.errorDescription ?? "Activation failed.")
            } catch {
                keyPhase = .error("Activation failed.")
            }
        }
    }

    // MARK: - In-app purchase

    private var iapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go Pro")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Associative recall — ask for memories by meaning, not keywords — plus everything Pro adds next.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            switch store.loadState {
            case .idle, .loading:
                ProgressView().tint(Theme.magenta)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                Button("Try again") {
                    Task { await store.loadProducts() }
                }
            case .loaded:
                if store.products.isEmpty {
                    Text("No purchase options are configured yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(store.products) { product in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.displayName)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if store.purchasingProductID == product.id {
                                ProgressView().tint(Theme.magenta)
                            } else {
                                Button(product.displayPrice) {
                                    Task { await store.purchase(product) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.magenta)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Button(store.restoring ? "Restoring…" : "Restore purchases") {
                Task { await store.restorePurchases() }
            }
            .disabled(store.restoring)
            .font(.footnote)
        }
        .themeCard()
    }

    /// Links a StoreKit-verified transaction to the desktop license.
    /// Fulfillment protocol (`iap:` key scheme) is assumed — see
    /// CONTRACT_DRIFT.md; B3 must confirm or replace it.
    private func linkPurchase(_ token: String) async {
        guard let api = appState.api else {
            store.notice = .init(isError: true, message: "This phone isn't paired.")
            return
        }
        do {
            let _: EmptyResponse = try await api.post(
                Endpoints.Remote.licenseActivate,
                body: LicenseActivateRequest(key: "iap:\(token)")
            )
            await refreshLicense()
            if appState.license?.isPro == true {
                store.notice = .init(isError: false, message: "Pro activated — enjoy!")
            } else {
                store.notice = .init(
                    isError: true,
                    message: "Apple verified your purchase, but your computer didn't switch to Pro. Your receipt is kept — tap Restore purchases to retry."
                )
            }
        } catch {
            store.notice = .init(
                isError: true,
                message: "Purchase verified, but linking failed: \((error as? APIError)?.errorDescription ?? "unknown error"). Tap Restore purchases to retry — you were charged by Apple, and your receipt is kept."
            )
        }
    }

    private func refreshLicense() async {
        guard let api = appState.api else { return }
        do {
            let status: LicenseStatus = try await api.get(Endpoints.Remote.licenseStatus)
            appState.license = status
        } catch {
            // The connection banner already surfaces network problems loudly.
        }
    }
}

private struct TierBadge: View {
    let isPro: Bool

    var body: some View {
        Text(isPro ? "PRO" : "FREE")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isPro ? Theme.magenta : Theme.textSecondary.opacity(0.4))
            .clipShape(Capsule())
    }
}

private struct NoticeBanner: View {
    let notice: StoreKitManager.Notice
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(notice.message)
                .font(.footnote)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
        }
        .foregroundStyle(notice.isError ? Theme.danger : Theme.success)
        .padding()
        .background((notice.isError ? Theme.danger : Theme.success).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
