import Foundation

// MARK: - Codable DTOs for the /api/remote/v1/ contract (ARCHITECTURE.md §1–3).
// Fields B2/B3 have not frozen are decoded tolerantly (optionals everywhere);
// anything still open is listed in ios/CONTRACT_DRIFT.md.

// MARK: Pairing

struct PairingExchangeRequest: Encodable {
    let code: String
    let device_name: String
    let device_model: String
}

struct PairingExchangeResponse: Decodable {
    let device_token: String
    let user_id: String
    let tier: String
    /// Assumed present (needed for self-unpair); nil-safe. See CONTRACT_DRIFT.md.
    let device_id: String?
}

struct PairedDevice: Decodable, Identifiable {
    var id: String { device_id }
    let device_id: String
    let device_name: String?
    let device_model: String?
    let created_at: String?
}

// MARK: License — mirrors backend LicenseStatusResponse (routers/license.py)

struct LicenseStatus: Decodable {
    let tier: String
    let key_id: String?
    let expires_at: String?
    let device_limit: Int?
    let devices_used: Int?
    let features: [String]?
    let reason: String?
    let message: String?
    let is_pro: Bool?

    var isPro: Bool { is_pro ?? (tier.lowercased() == "pro") }

    var expiryDate: Date? {
        guard let expires_at else { return nil }
        return ISO8601DateFormatter().date(from: expires_at)
    }

    /// Days until expiry, negative when expired. Nil when no expiry.
    var daysUntilExpiry: Int? {
        guard let expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day
    }
}

struct LicenseActivateRequest: Encodable {
    let key: String
}

// MARK: Agent control

struct AgentStatus: Decodable {
    let active_runs: Int?
    let queue_depth: Int?
    let model: String?
}

struct WakeResponse: Decodable {
    let server_time: String?
    let license: LicenseStatus?
}

// MARK: Threads / runs

struct ThreadResponse: Decodable {
    let thread_id: String
    let status: String?
    let created_at: String?
    let updated_at: String?
}

struct ThreadSearchRequest: Encodable {
    var metadata: [String: String] = [:]
    var limit: Int = 50
    var offset: Int = 0
    var status: String? = nil
}

struct ThreadCreateRequest: Encodable {
    var thread_id: String? = nil
    var assistant_id: String? = nil
    var metadata: [String: String] = [:]
}

struct RunInputMessage: Encodable {
    let role: String // "human" | "ai"
    let content: String
}

/// Mirrors backend RunCreateRequest (subset the phone needs).
struct RunCreateRequest: Encodable {
    struct Input: Encodable {
        let messages: [RunInputMessage]
    }
    let input: Input?
    let stream_mode: [String]?
    let on_disconnect: String? // "continue" — runs survive the phone sleeping
}

/// Request body for the NEW alias POST /api/remote/v1/chat/stream.
/// Exact shape to be confirmed with B2 — see CONTRACT_DRIFT.md.
struct ChatStreamRequest: Encodable {
    let thread_id: String?
    let input: RunCreateRequest.Input
    let stream_mode: [String]?
    let on_disconnect: String?
}

struct ThreadTokenUsage: Decodable {
    let total_input_tokens: Int?
    let total_output_tokens: Int?
    let total_tokens: Int?
}

// MARK: Messages (tolerant — content may be a string or content blocks)

struct ContentBlock: Decodable {
    let type: String?
    let text: String?
}

struct ChatMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String

    /// For locally-created messages (user input, streaming placeholder).
    init(id: String = UUID().uuidString, role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case id, role, type, content, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        role = (try? c.decode(String.self, forKey: .role))
            ?? (try? c.decode(String.self, forKey: .type))
            ?? "unknown"
        if let s = try? c.decode(String.self, forKey: .content) {
            content = s
        } else if let blocks = try? c.decode([ContentBlock].self, forKey: .content) {
            content = blocks.compactMap(\.text).joined(separator: "\n")
        } else {
            content = (try? c.decode(String.self, forKey: .text)) ?? ""
        }
    }
}

struct PaginatedMessages: Decodable {
    let data: [ChatMessage]?
    let has_more: Bool?

    var messages: [ChatMessage] { data ?? [] }
}

// MARK: Memory (free tier) — shapes verified against backend memory.py

struct MemoryFact: Decodable, Identifiable {
    let id: String
    let content: String
    let category: String
    let confidence: Double
    let createdAt: String
    let source: String
    let sourceError: String?
}

struct MemoryResponse: Decodable {
    let facts: [MemoryFact]?
}

struct FactCreateRequest: Encodable {
    let content: String
    let category: String
    let confidence: Double
}

struct FactPatchRequest: Encodable {
    let content: String?
    let category: String?
    let confidence: Double?
}

// MARK: Associative memory (paid tier) — shapes assumed, see CONTRACT_DRIFT.md

struct RecallRequest: Encodable {
    let query: String
    let top_k: Int?
}

struct RecallHit: Decodable {
    let content: String?
    let score: Double?
}

struct RecallResponse: Decodable {
    let results: [RecallHit]?
}

struct RetainRequest: Encodable {
    let content: String
}
