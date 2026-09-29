import Foundation

/// Metadata from `GET /api/remote/v1/byok/status`.
/// The key itself is never returned by the desktop — status only.
struct BYOKKeyStatus: Decodable, Equatable, Sendable {
    let configured: Bool
    let provider: String?
    let model: String?
    let active: Bool?
    let last_validated_at: String?

    var providerEnum: BYOKProvider? {
        provider.flatMap(BYOKProvider.init(rawValue:))
    }

    var lastValidatedDate: Date? {
        guard let last_validated_at else { return nil }
        return ISO8601DateFormatter().date(from: last_validated_at)
    }
}
