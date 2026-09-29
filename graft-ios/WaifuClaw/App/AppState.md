# WaifuClaw/App/AppState.swift

- PairedComputer · struct · L6-L17 — struct PairedComputer: Equatable
- ConnectionState · enum · L20-L30 — enum ConnectionState: Equatable
- FingerprintAlert · struct · L33-L37 — struct FingerprintAlert: Identifiable
- AppState · class · L39-L227 — @MainActor final class AppState: ObservableObject
- Pairing · enum · L41-L44 — enum Pairing: Equatable
- Keys · enum · L59-L65 — private enum Keys
- restore · method · L70-L88 — func restore()
- completePairing · method · L91-L113 — func completePairing(payload: PairingPayload, response: PairingExchangeResponse, manualHost: String?)
- unpair · method · L117-L133 — func unpair() async
- refreshConnection · method · L137-L153 — func refreshConnection() async
- startWakePolling · method · L156-L163 — func startWakePolling()
- handleFingerprintMismatch · method · L168-L172 — nonisolated func handleFingerprintMismatch(expected: String, actual: String)
- trustNewFingerprint · method · L175-L181 — func trustNewFingerprint()
- dismissSecurityAlert · method · L183-L185 — func dismissSecurityAlert()
- setPaired · method · L189-L202 — private func setPaired(_ computer: PairedComputer)
- kind · method · L205-L208 — nonisolated static func kind(for host: String) -> ConnectionKind
- splitHostPort · method · L212-L226 — nonisolated static func splitHostPort(_ raw: String) -> (host: String, port: Int)
