import SwiftUI

/// Root of the pairing flow. Shows discovery first (which leads to the scanner).
struct PairingFlowView: View {
    var body: some View {
        NavigationStack {
            DiscoveryView()
        }
    }
}

/// After a successful scan: shows what will be paired, the TOFU fingerprint,
/// a live expiry countdown for the 600 s pairing code, and the Pair button.
/// Expired codes fail loudly (audit §3) — never a silent spinner.
struct PairingConfirmView: View {
    @EnvironmentObject var appState: AppState
    let qrString: String
    let manualHost: String?

    @State private var payload: PairingPayload?
    @State private var parseError: String?
    @State private var secondsLeft = 600
    @State private var phase: Phase = .idle
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case pairing
        case error(String)
        case expired
    }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    if let payload {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 56))
                            .foregroundStyle(Theme.magenta)

                        Text("Pair this computer?")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)

                        VStack(alignment: .leading, spacing: 8) {
                            LabeledRow(label: "Address", value: effectiveHost)
                            LabeledRow(label: "Security fingerprint", value: payload.fingerprintPreview, mono: true)
                        }
                        .themeCard()
                        .padding(.horizontal)

                        Text("Check that the fingerprint matches the one shown on your computer's screen. It only has to match the first time — after that, your phone remembers it.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal)

                        // Live expiry countdown (audit §3).
                        HStack {
                            Image(systemName: "timer")
                            Text(countdownText)
                                .monospacedDigit()
                        }
                        .foregroundStyle(secondsLeft < 60 ? Theme.warning : Theme.textSecondary)

                        switch phase {
                        case .idle:
                            Button("Pair this computer") { pair() }
                                .themePrimaryButton()
                                .padding(.horizontal, 32)
                        case .pairing:
                            ProgressView("Pairing…")
                                .tint(Theme.magenta)
                                .foregroundStyle(Theme.textSecondary)
                        case .error(let message):
                            Text(message)
                                .foregroundStyle(Theme.danger)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Try again") { pair() }
                                .themePrimaryButton()
                                .padding(.horizontal, 32)
                        case .expired:
                            VStack(spacing: 12) {
                                Text("That code expired.")
                                    .font(.headline)
                                    .foregroundStyle(Theme.warning)
                                Text("On your computer, open WaifuClaw → Settings → Phone remote and generate a new code, then scan it.")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Theme.textSecondary)
                                Button("Scan a new code") { dismiss() }
                                    .themePrimaryButton()
                            }
                            .padding(.horizontal, 32)
                        }
                    } else if let parseError {
                        VStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.danger)
                            Text(parseError)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.textSecondary)
                            Button("Scan again") { dismiss() }
                                .themePrimaryButton()
                                .padding(.horizontal, 32)
                        }
                        .padding()
                    }
                    Spacer(minLength: 24)
                }
                .padding(.top, 24)
            }
        }
        .navigationTitle("Confirm pairing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                payload = try PairingPayload.parse(qrString)
            } catch {
                parseError = error.localizedDescription
            }
        }
        .onReceive(timer) { _ in
            guard payload != nil, phase == .idle, secondsLeft > 0 else { return }
            secondsLeft -= 1
            if secondsLeft == 0 { phase = .expired }
        }
    }

    private var effectiveHost: String {
        (manualHost?.isEmpty == false) ? manualHost! : (payload?.host ?? "")
    }

    private var countdownText: String {
        if secondsLeft <= 0 { return "Code expired" }
        let m = secondsLeft / 60, s = secondsLeft % 60
        return String(format: "Code expires in %d:%02d", m, s)
    }

    private func pair() {
        guard let payload else { return }
        phase = .pairing
        let client = PairingClient(
            host: effectiveHost,
            fingerprint: payload.fingerprint,
            onMismatch: { [weak appState] expected, actual in
                appState?.handleFingerprintMismatch(expected: expected, actual: actual)
            }
        )
        Task {
            do {
                // Pin the QR fingerprint for this exchange's TLS handshake (TOFU).
                KeychainStore.pinnedFingerprint = payload.fingerprint
                let body = PairingExchangeRequest(
                    code: payload.code,
                    device_name: UIDevice.current.name,
                    device_model: UIDevice.current.model
                )
                let response = try await client.exchange(body)
                appState.completePairing(payload: payload, response: response, manualHost: manualHost)
            } catch let apiError as APIError {
                if case .pairingCodeExpired = apiError {
                    phase = .expired
                } else if case .tlsMismatch = apiError {
                    // The blocking security warning is already on screen (audit §4).
                    phase = .idle
                } else {
                    phase = .error(apiError.errorDescription ?? "Pairing failed.")
                }
            } catch {
                phase = .error("Pairing failed. Check the address and try again.")
            }
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .font(mono ? .body.monospaced() : .body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
