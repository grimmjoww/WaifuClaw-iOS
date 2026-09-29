import Foundation

/// Which network the paired computer was reached on. Drives the
/// per-state unreachable messages (audit §6).
enum ConnectionKind: Equatable {
    case lan
    case tunnel
}

/// Typed API failures. Every case maps to a loud, plain-words UI message —
/// never a spinner, never a blank screen (audit Q3).
enum APIError: LocalizedError {
    case notPaired
    case deviceRevoked
    case pairingCodeExpired
    case paymentRequired // 402 — paid endpoint on the free tier
    case byokKeyInvalid(provider: String) // provider rejected the stored BYOK key mid-run
    case unreachable(kind: ConnectionKind)
    case desktopNotResponding
    case tlsMismatch(expected: String, actual: String)
    case http(status: Int, message: String?)
    case network(URLError)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "This phone isn't paired yet."
        case .deviceRevoked:
            return "This phone was unpaired from your computer."
        case .pairingCodeExpired:
            return "That code expired — ask your computer for a new one."
        case .paymentRequired:
            return "Associative recall is a Pro feature."
        case .byokKeyInvalid(let provider):
            let name = BYOKProvider(rawValue: provider)?.displayName ?? provider
            return "Your \(name) key was rejected — update it in Settings → API Key."
        case .unreachable(let kind):
            switch kind {
            case .lan:
                return "Can't reach your computer — is it awake and on the same network?"
            case .tunnel:
                return "Can't reach your computer through the tunnel — is Tailscale running on both devices?"
            }
        case .desktopNotResponding:
            return "Your computer isn't responding — is the WaifuClaw app running?"
        case .tlsMismatch:
            return "Security warning: your computer's identity changed."
        case .http(let status, let message):
            return message ?? "Request failed (HTTP \(status))."
        case .network(let urlError):
            return urlError.localizedDescription
        case .decoding:
            return "Couldn't understand the response from your computer."
        }
    }
}
