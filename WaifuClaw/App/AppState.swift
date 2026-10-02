import Foundation
import SwiftUI

/// Information about the paired desktop computer (non-secret parts live in
/// UserDefaults; the device token and TLS pin live in the Keychain).
struct PairedComputer: Equatable {
    let host: String // as scanned/entered, without scheme or port
    let port: Int
    let deviceName: String
    let userID: String
    let deviceID: String?
    let kind: ConnectionKind

    var baseURL: URL { URL(string: "https://\(host):\(port)")! }

    var displayName: String { "\(deviceName) · \(host)" }
}

/// Connection health for the persistent indicator (audit §6).
enum ConnectionState: Equatable {
    case unknown
    case checking
    case connected(kind: ConnectionKind)
    case notConnected(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Data for the blocking TOFU-mismatch warning (audit §4).
struct FingerprintAlert: Identifiable {
    let id = UUID()
    let expected: String
    let actual: String
}

@MainActor
final class AppState: ObservableObject {
    enum Pairing: Equatable {
        case unpaired
        case paired(PairedComputer)
    }

    @Published var pairing: Pairing = .unpaired
    @Published var connection: ConnectionState = .unknown
    @Published var license: LicenseStatus?
    @Published var securityAlert: FingerprintAlert?
    @Published var showRevokedNotice = false
    /// TabView selection — features can route the user to the Pro tab (e.g.
    /// the 402 upsell in Memory).
    @Published var tabSelection = 0

    private(set) var api: APIClient?

    // MARK: - UserDefaults (non-secret pairing material only)

    private enum Keys {
        static let host = "wc.paired.host"
        static let port = "wc.paired.port"
        static let deviceName = "wc.paired.deviceName"
        static let userID = "wc.paired.userID"
        static let deviceID = "wc.paired.deviceID"
    }

    // MARK: - Restore / pair / unpair

    /// Cold start: rebuild the client from stored pairing material, if any.
    func restore() {
        guard let host = UserDefaults.standard.string(forKey: Keys.host),
              KeychainStore.deviceToken != nil
        else {
            pairing = .unpaired
            return
        }
        let storedPort = UserDefaults.standard.integer(forKey: Keys.port)
        let computer = PairedComputer(
            host: host,
            port: storedPort > 0 ? storedPort : 8001,
            deviceName: UserDefaults.standard.string(forKey: Keys.deviceName) ?? "My computer",
            userID: UserDefaults.standard.string(forKey: Keys.userID) ?? "",
            deviceID: UserDefaults.standard.string(forKey: Keys.deviceID),
            kind: Self.kind(for: host)
        )
        setPaired(computer)
        Task { await refreshConnection() }
    }

    /// Called after a successful pairing exchange.
    func completePairing(payload: PairingPayload, response: PairingExchangeResponse, manualHost: String?) {
        let rawHost = (manualHost?.isEmpty == false) ? manualHost! : payload.host
        let (host, port) = Self.splitHostPort(rawHost)
        KeychainStore.deviceToken = response.device_token
        KeychainStore.pinnedFingerprint = payload.fingerprint
        UserDefaults.standard.set(host, forKey: Keys.host)
        UserDefaults.standard.set(port, forKey: Keys.port)
        UserDefaults.standard.set(UIDevice.current.name, forKey: Keys.deviceName)
        UserDefaults.standard.set(response.user_id, forKey: Keys.userID)
        if let deviceID = response.device_id {
            UserDefaults.standard.set(deviceID, forKey: Keys.deviceID)
        }
        let computer = PairedComputer(
            host: host,
            port: port,
            deviceName: UIDevice.current.name,
            userID: response.user_id,
            deviceID: response.device_id,
            kind: Self.kind(for: host)
        )
        setPaired(computer)
        Task { await refreshConnection() }
    }

    /// "Unpair this phone" (Settings). Best-effort server-side revoke, then
    /// local wipe. The button exists and the failure is loud (audit Q1/Q3).
    func unpair() async {
        if case .paired(let computer) = pairing,
           let deviceID = computer.deviceID,
           let api
        {
            // Best effort: even if this fails, we still wipe locally below.
            _ = try? await api.delete(Endpoints.Remote.pairingDevice(deviceID)) as EmptyResponse
        }
        KeychainStore.wipePairingCredentials()
        for key in [Keys.host, Keys.port, Keys.deviceName, Keys.userID, Keys.deviceID] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        api = nil
        license = nil
        connection = .unknown
        pairing = .unpaired
    }

    // MARK: - Connection health (the `wake` poll drives the indicator)

    func refreshConnection() async {
        guard case .paired(let computer) = pairing, let api else { return }
        connection = .checking
        do {
            let wake: WakeResponse = try await api.post(Endpoints.Remote.agentWake)
            if let license = wake.license { self.license = license }
            connection = .connected(kind: computer.kind)
        } catch let apiError as APIError {
            if case .deviceRevoked = apiError {
                showRevokedNotice = true
                return
            }
            connection = .notConnected(message: apiError.errorDescription ?? "Not connected.")
        } catch {
            connection = .notConnected(message: "Not connected.")
        }
    }

    /// Poll `wake` every 30 s while the app is active.
    func startWakePolling() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if case .paired = pairing { await refreshConnection() }
            }
        }
    }

    // MARK: - Security

    /// Called (off-main) by the TLS pinning delegate on fingerprint mismatch.
    nonisolated func handleFingerprintMismatch(expected: String, actual: String) {
        Task { @MainActor in
            self.securityAlert = FingerprintAlert(expected: expected, actual: actual)
        }
    }

    /// User explicitly trusts the new certificate. Never automatic (audit §4).
    func trustNewFingerprint() {
        if let alert = securityAlert {
            KeychainStore.pinnedFingerprint = alert.actual
        }
        securityAlert = nil
        Task { await refreshConnection() }
    }

    func dismissSecurityAlert() {
        securityAlert = nil
    }

    // MARK: - Private

    private func setPaired(_ computer: PairedComputer) {
        let client = APIClient(
            baseURL: computer.baseURL,
            connectionKind: { computer.kind },
            onMismatch: { [weak self] expected, actual in
                self?.handleFingerprintMismatch(expected: expected, actual: actual)
            },
            onDeviceRevoked: { [weak self] in
                Task { @MainActor in self?.showRevokedNotice = true }
            }
        )
        self.api = client
        self.pairing = .paired(computer)
    }

    /// Tailscale heuristic: 100.64.0.0/10 IPs or *.ts.net hostnames.
    nonisolated static func kind(for host: String) -> ConnectionKind {
        if host.hasSuffix(".ts.net") || host.hasPrefix("100.") { return .tunnel }
        return .lan
    }

    /// Splits "host:port"; defaults to 8001. Port default confirmed with B2 —
    /// see CONTRACT_DRIFT.md.
    nonisolated static func splitHostPort(_ raw: String) -> (host: String, port: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // IPv6 literals ([::1]:8001) — keep it simple and correct for the common case.
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            let port = Int(rest.dropFirst()) ?? 8001
            return (host, port)
        }
        let parts = trimmed.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return (trimmed, 8001)
    }
}
