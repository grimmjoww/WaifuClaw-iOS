import Foundation

/// Body for `POST /api/remote/v1/byok/key`.
/// Upsert semantics — posting again rotates the key.
struct BYOKSaveRequest: Encodable, Sendable {
    let provider: String
    let api_key: String
    let model: String?
    let base_url: String?
}
