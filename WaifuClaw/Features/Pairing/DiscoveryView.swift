import Foundation
import SwiftUI

/// Bonjour discovery for `_waifuclaw._tcp` (ARCHITECTURE.md §2.2).
@MainActor
final class DiscoveryBrowser: NSObject, ObservableObject {
    @Published var services: [NetService] = []
    @Published var isSearching = false

    private var browser: NetServiceBrowser?

    func start() {
        stop()
        isSearching = true
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_waifuclaw._tcp", inDomain: "")
    }

    func stop() {
        browser?.stop()
        browser = nil
        isSearching = false
    }

    deinit {
        // MainActor-isolated deinit is not allowed to touch actor state;
        // the browser is stopped explicitly via stop().
    }
}

extension DiscoveryBrowser: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            service.delegate = self
            service.resolve(withTimeout: 5)
            if !self.services.contains(where: { $0.name == service.name }) {
                self.services.append(service)
            }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            self.services.removeAll { $0.name == service.name }
        }
    }
}

extension DiscoveryBrowser: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in self.objectWillChange.send() }
    }
}

/// First pairing screen: discovered computers, QR scan entry, manual host.
/// Empty state per audit §5 — never a bare empty list.
struct DiscoveryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var browser = DiscoveryBrowser()
    @State private var manualHost = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.magenta)
                        .padding(.top, 24)

                    Text("Pair your computer")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)

                    Text("On your computer, open WaifuClaw → Settings → Phone remote → Pair phone, then scan the QR code.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal)

                    Button("Scan QR code") { showScanner = true }
                        .themePrimaryButton()
                        .padding(.horizontal, 32)

                    Divider().background(Theme.textSecondary.opacity(0.3))

                    // Discovered computers (informational — the QR is the source of truth).
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Computers nearby")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if browser.isSearching { ProgressView().tint(Theme.magenta) }
                        }
                        if browser.services.isEmpty {
                            // Audit §5: empty state with explanation + fallback.
                            VStack(spacing: 8) {
                                Text("No computers found — is WaifuClaw running with Phone remote turned on?")
                                    .foregroundStyle(Theme.textSecondary)
                                Text("You can still pair by scanning the QR code above, or enter the address manually below.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .themeCard()
                        } else {
                            ForEach(browser.services, id: \.name) { service in
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(Theme.magenta)
                                    VStack(alignment: .leading) {
                                        Text(service.name)
                                            .foregroundStyle(Theme.textPrimary)
                                        if let host = service.hostName {
                                            Text(host)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                .themeCard()
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Manual host fallback (audit §5).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter address manually")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        TextField("e.g. 192.168.1.20 or my-pc.tailnet.ts.net", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Use this if the QR code's address doesn't work on your network. You'll still scan the QR for the security code.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Pair phone")
        .navigationDestination(isPresented: $showScanner) {
            QRScannerView(manualHost: manualHost.isEmpty ? nil : manualHost)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}
