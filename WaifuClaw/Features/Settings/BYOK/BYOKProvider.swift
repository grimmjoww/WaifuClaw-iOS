import Foundation

/// BYOK provider registry — the phone's affordance table.
///
/// Ids match the desktop setup-wizard registry (`scripts/wizard/providers.py`);
/// the desktop is authoritative and rejects unknown ids with
/// `byok_unsupported_provider`.
enum BYOKProvider: String, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic
    case deepseek
    case google
    case openaiCompatible = "openai_compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .deepseek: "DeepSeek"
        case .google: "Google Gemini"
        case .openaiCompatible: "Custom (OpenAI-compatible)"
        }
    }

    /// Model used when the user leaves the model field blank. Nil means the
    /// user must supply one (custom endpoints have no sane default).
    var defaultModel: String? {
        switch self {
        case .openai: "gpt-5"
        case .anthropic: "claude-sonnet-4-20250514"
        case .deepseek: "deepseek-reasoner"
        case .google: "gemini-2.5-pro"
        case .openaiCompatible: nil
        }
    }

    /// Inline format hint shown under the key field. Hints only — validation
    /// is always the live provider probe, never a regex.
    var keyHint: String {
        switch self {
        case .openai, .deepseek: "Keys from \(displayName) start with “sk-”."
        case .anthropic: "Keys from Anthropic start with “sk-ant-”."
        case .google: "Keys from Google start with “AIza”."
        case .openaiCompatible: "Paste the API key your endpoint expects."
        }
    }

    var requiresBaseURL: Bool { self == .openaiCompatible }

    /// Whether a pasted key looks like this provider's format. Advisory only.
    func keyLooksRight(_ key: String) -> Bool {
        switch self {
        case .openai, .deepseek: key.hasPrefix("sk-")
        case .anthropic: key.hasPrefix("sk-ant-")
        case .google: key.hasPrefix("AIza")
        case .openaiCompatible: true
        }
    }

    /// Builds the key-validation probe. Header auth only — the key never
    /// appears in a URL, and the request is never logged.
    /// Returns nil when the provider needs a base URL and none was given.
    func validationRequest(key: String, baseURL: String?) -> URLRequest? {
        let request: URLRequest
        switch self {
        case .openai:
            guard let url = URL(string: "https://api.openai.com/v1/models") else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request = req
        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return nil }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request = req
        case .deepseek:
            guard let url = URL(string: "https://api.deepseek.com/v1/models") else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request = req
        case .google:
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
                return nil
            }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request = req
        case .openaiCompatible:
            let trimmed = (baseURL ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, let url = URL(string: "\(trimmed)/v1/models") else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request = req
        }
        var mutable = request
        mutable.httpMethod = "GET"
        mutable.timeoutInterval = 15
        return mutable
    }
}
