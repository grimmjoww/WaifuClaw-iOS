# WaifuClaw/Features/Pairing/DiscoveryView.swift

- DiscoveryBrowser · class · L5-L31 — @MainActor final class DiscoveryBrowser: NSObject, ObservableObject
- start · method · L12-L19 — func start()
- stop · method · L21-L25 — func stop()
- DiscoveryBrowser · module · L33-L57 — extension DiscoveryBrowser: NetServiceBrowserDelegate
- netServiceBrowser · method · L34-L46 — nonisolated func netServiceBrowser( _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool )
- netServiceBrowser · method · L48-L56 — nonisolated func netServiceBrowser( _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool )
- DiscoveryBrowser · module · L59-L63 — extension DiscoveryBrowser: NetServiceDelegate
- netServiceDidResolveAddress · method · L60-L62 — nonisolated func netServiceDidResolveAddress(_ sender: NetService)
- DiscoveryView · struct · L67-L163 — struct DiscoveryView: View
