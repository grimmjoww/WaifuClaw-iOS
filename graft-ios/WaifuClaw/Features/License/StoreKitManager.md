# WaifuClaw/Features/License/StoreKitManager.swift

- StoreKitManager · class · L9-L130 — @MainActor final class StoreKitManager: ObservableObject
- LoadState · enum · L14-L19 — enum LoadState: Equatable
- Notice · struct · L21-L25 — struct Notice: Identifiable, Equatable
- StoreKitManager · method · L40-L44 — init()
- loadProducts · method · L50-L60 — func loadProducts() async
- purchase · method · L62-L94 — func purchase(_ product: Product) async
- restorePurchases · method · L96-L116 — func restorePurchases() async
- listenForTransactions · method · L121-L129 — private func listenForTransactions() async
