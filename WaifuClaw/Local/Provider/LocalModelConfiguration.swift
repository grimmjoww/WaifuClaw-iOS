import Foundation

/// Metadata only. Provider keys live in the Keychain, never UserDefaults.
struct LocalModelConfiguration: Sendable, Equatable {
    let endpoint: URL
    let model: String

    init(endpointText: String, modelText: String) throws {
        let trimmedModel = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, trimmedModel.count <= 120 else {
            throw LocalModelConfigurationError.invalidModel
        }
        let trimmedEndpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedEndpoint),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host.contains("."),
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              host.rangeOfCharacter(from: .letters) != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url
        else { throw LocalModelConfigurationError.invalidEndpoint }
        // The model protocol must not silently send project context to a local
        // HTTP service or a URL containing a token in its query parameters.
        endpoint = url
        model = trimmedModel
    }
}

enum LocalModelConfigurationError: LocalizedError {
    case invalidModel
    case invalidEndpoint
    case notConfigured
    case missingKey

    var errorDescription: String? {
        switch self {
        case .invalidModel: "Enter the exact model ID supported by your provider."
        case .invalidEndpoint: "Enter a public HTTPS provider base URL without a key, query or fragment."
        case .notConfigured: "Choose a model and provider in Settings before starting an agent run."
        case .missingKey: "Add your provider key in Settings before starting an agent run."
        }
    }
}

enum LocalModelPreferences {
    static let endpointKey = "native.model.endpoint"
    static let modelKey = "native.model.name"
    static let defaultEndpoint = "https://api.openai.com/v1"

    static func load() throws -> LocalModelConfiguration {
        guard let endpoint = UserDefaults.standard.string(forKey: endpointKey),
              let model = UserDefaults.standard.string(forKey: modelKey) else {
            throw LocalModelConfigurationError.notConfigured
        }
        return try LocalModelConfiguration(endpointText: endpoint, modelText: model)
    }

    static func save(_ configuration: LocalModelConfiguration) {
        UserDefaults.standard.set(configuration.endpoint.absoluteString, forKey: endpointKey)
        UserDefaults.standard.set(configuration.model, forKey: modelKey)
    }
}
