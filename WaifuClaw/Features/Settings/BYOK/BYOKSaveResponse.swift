import Foundation

/// Response for `POST /api/remote/v1/byok/key`.
struct BYOKSaveResponse: Decodable, Sendable {
    let provider: String
    let model: String?
    let active: Bool
    let validated: Bool
    let last_validated_at: String?
}
