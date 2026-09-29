import Foundation

/// Typed BYOK failures. Every case maps to a loud, plain-words message —
/// a bad key is never silent and never falls back to anything.
enum BYOKError: LocalizedError {
    case keyRejected(provider: BYOKProvider) // 401/403 on the direct probe
    case providerUnreachable(provider: BYOKProvider) // network/timeout/5xx on the probe
    case probeRateLimited(provider: BYOKProvider) // 429 on the probe (warning, not fatal)
    case desktopRejected(detail: String) // 400 from the desktop
    case desktopTooOld // 404 — desktop predates BYOK
    case desktopRateLimited // 429 from the desktop
    case invalidBaseURL
    case underlying(APIError)

    var errorDescription: String? {
        switch self {
        case .keyRejected(let provider):
            "That key was rejected by \(provider.displayName). Check it and try again."
        case .providerUnreachable(let provider):
            "Couldn't reach \(provider.displayName) to check the key — is this phone online?"
        case .probeRateLimited(let provider):
            "\(provider.displayName) is rate-limiting right now."
        case .desktopRejected(let detail):
            detail
        case .desktopTooOld:
            "Your computer's WaifuClaw doesn't support phone key sync yet — update it."
        case .desktopRateLimited:
            "Your computer is being rate-limited — try again in a bit."
        case .invalidBaseURL:
            "That base URL doesn't look right — it should start with https://."
        case .underlying(let apiError):
            apiError.errorDescription
        }
    }
}
