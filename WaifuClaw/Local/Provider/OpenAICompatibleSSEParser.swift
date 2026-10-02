import Foundation

/// Stateful parser for OpenAI Chat Completions SSE frames.
///
/// The parser is deliberately transport-free so its framing and incremental
/// tool-call behavior can be tested without a network server.
struct OpenAICompatibleSSEParser {
    private var dataLines: [String] = []
    private var partialToolCalls: [Int: PartialToolCall] = [:]
    private var didFinish = false

    /// Consumes one line from an SSE response. A blank line ends an SSE frame.
    mutating func consume(line: String) throws -> [AgentProviderEvent] {
        guard !didFinish else { return [] }

        if line.hasPrefix("data:") {
            var payload = String(line.dropFirst("data:".count))
            if payload.first == " " {
                payload.removeFirst()
            }
            dataLines.append(payload)
            return []
        }

        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try consumeCompletedFrame()
        }

        // `event:`, `id:`, `retry:`, and comment lines do not alter the Chat
        // Completions JSON payload, so they are intentionally ignored.
        return []
    }

    /// Completes a stream at EOF. A valid OpenAI stream must have already sent
    /// a terminal finish reason or the `[DONE]` sentinel.
    mutating func finishInput() throws -> [AgentProviderEvent] {
        var events = try consumeCompletedFrame()
        guard didFinish else { throw AgentProviderError.malformedStream }
        return events
    }

    private mutating func consumeCompletedFrame() throws -> [AgentProviderEvent] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)

        if payload == "[DONE]" {
            return try finish()
        }

        guard let data = payload.data(using: .utf8) else {
            throw AgentProviderError.malformedStream
        }

        let chunk: ChatCompletionChunk
        do {
            chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        } catch {
            throw AgentProviderError.malformedStream
        }

        guard let choice = chunk.choices.first else {
            throw AgentProviderError.malformedStream
        }

        var events: [AgentProviderEvent] = []
        if let content = choice.delta.content, !content.isEmpty {
            events.append(.text(content))
        }

        if let toolCalls = choice.delta.toolCalls {
            for toolCall in toolCalls {
                try append(toolCall)
            }
        }

        if choice.finishReason != nil {
            events.append(contentsOf: try finish())
        }
        return events
    }

    private mutating func append(_ delta: ToolCallDelta) throws {
        guard let index = delta.index, index >= 0 else {
            throw AgentProviderError.malformedStream
        }
        if let type = delta.type, type != "function" {
            throw AgentProviderError.malformedStream
        }

        var call = partialToolCalls[index] ?? PartialToolCall()
        if let id = delta.id { call.id += id }
        if let name = delta.function?.name { call.name += name }
        if let arguments = delta.function?.arguments { call.arguments += arguments }
        partialToolCalls[index] = call
    }

    private mutating func finish() throws -> [AgentProviderEvent] {
        guard !didFinish else { return [] }
        didFinish = true

        var events: [AgentProviderEvent] = []
        for (index, call) in partialToolCalls.sorted(by: { $0.key < $1.key }) {
            guard !call.id.isEmpty, !call.name.isEmpty else {
                throw AgentProviderError.incompleteToolCall(index: index)
            }
            events.append(.toolCall(
                AgentToolCall(id: call.id, name: call.name, argumentsJSON: call.arguments)
            ))
        }
        events.append(.finished)
        return events
    }
}

private extension OpenAICompatibleSSEParser {
    struct PartialToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    struct ChatCompletionChunk: Decodable {
        let choices: [Choice]
    }

    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let type: String?
        let function: Function?
    }

    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }
}
