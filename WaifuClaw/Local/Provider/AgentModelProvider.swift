import Foundation

/// A single message supplied to an agent model provider.
///
/// `toolCallID` is used for a `tool` role message, while `toolCalls` preserves
/// function calls made by an `assistant` role message for the next model turn.
struct AgentPromptMessage: Sendable {
    let role: String
    let content: String
    let toolCallID: String?
    let toolCalls: [AgentToolCall]?

    init(
        role: String,
        content: String,
        toolCallID: String? = nil,
        toolCalls: [AgentToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

/// A local tool made available to a model. The provider only describes tools;
/// tool authorization and execution remain the responsibility of the agent.
struct AgentToolDefinition: Sendable {
    let name: String
    let description: String
    let parametersJSON: Data

    init(name: String, description: String, parametersJSON: Data) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// A function call requested by the model. `argumentsJSON` is the model's raw,
/// incrementally assembled JSON argument string and is never executed here.
struct AgentToolCall: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Events emitted while a model response is streamed.
enum AgentProviderEvent: Sendable {
    case text(String)
    case toolCall(AgentToolCall)
    case finished
}

/// Transport-agnostic local model-provider interface.
protocol AgentModelProvider: Sendable {
    func stream(
        messages: [AgentPromptMessage],
        tools: [AgentToolDefinition]
    ) -> AsyncThrowingStream<AgentProviderEvent, Error>
}

/// Errors intentionally omit request and response bodies so API keys, prompts,
/// tool arguments, and provider error payloads cannot be surfaced accidentally.
enum AgentProviderError: LocalizedError, Sendable {
    case emptyAPIKey
    case emptyModel
    case invalidBaseURL
    case insecureBaseURL
    case unsafeHost
    case hostResolutionFailed
    case invalidToolDefinition(name: String)
    case requestEncoding
    case redirected
    case httpStatus(Int)
    case malformedStream
    case incompleteToolCall(index: Int)
    case network

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "An API key is required."
        case .emptyModel:
            return "A model name is required."
        case .invalidBaseURL:
            return "The provider URL is invalid."
        case .insecureBaseURL:
            return "The provider URL must use HTTPS."
        case .unsafeHost:
            return "The provider URL must resolve only to a public host."
        case .hostResolutionFailed:
            return "The provider host could not be resolved safely."
        case .invalidToolDefinition(let name):
            return "The tool definition for \(name) has invalid JSON parameters."
        case .requestEncoding:
            return "The model request could not be encoded."
        case .redirected:
            return "The model provider attempted an unsupported redirect."
        case .httpStatus(let status):
            return "The model provider rejected the request (HTTP \(status))."
        case .malformedStream:
            return "The model provider returned an invalid streaming response."
        case .incompleteToolCall(let index):
            return "The model provider returned an incomplete tool call at index \(index)."
        case .network:
            return "The model provider could not be reached."
        }
    }
}
