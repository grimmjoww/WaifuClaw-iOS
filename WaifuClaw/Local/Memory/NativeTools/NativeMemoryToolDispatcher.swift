import Foundation

/// Dispatches the two allowlisted native memory reads against the actor-isolated
/// `LocalNeuralMemoryStore`. This type has no write API, no URLSession, no file
/// access, and no path to raw SQLite rows or credentials.
struct NativeMemoryToolDispatcher: Sendable {
    private let memoryStore: LocalNeuralMemoryStore

    init(memoryStore: LocalNeuralMemoryStore) {
        self.memoryStore = memoryStore
    }

    /// Parent-agent entry point for a provider-produced function call.
    func dispatch(
        _ call: AgentToolCall,
        access: NativeMemoryToolAccessContext
    ) async -> NativeMemoryToolDispatchResult {
        await dispatch(name: call.name, argumentsJSON: call.argumentsJSON, access: access)
    }

    /// Parent-agent entry point when the caller stores a call in another typed
    /// representation. `argumentsJSON` must be the provider's unmodified JSON
    /// argument object, never a hand-built dictionary.
    func dispatch(
        name: String,
        argumentsJSON: String,
        access: NativeMemoryToolAccessContext
    ) async -> NativeMemoryToolDispatchResult {
        let upstreamTool = NativeMemoryUpstreamTool(rawValue: name)
        let eventToolName = upstreamTool?.rawValue ?? "native_memory_unavailable"

        do {
            try Task.checkCancellation()

            let availability = NativeMemoryToolRegistry.availability(for: access)
            guard case let .available(projectID) = availability else {
                let code: NativeMemoryToolErrorCode
                if case let .unavailable(unavailableCode) = availability {
                    code = unavailableCode
                } else {
                    code = .projectNotSelected
                }
                return failure(toolName: eventToolName, code: code)
            }

            guard let upstreamTool else {
                return failure(toolName: eventToolName, code: .unavailableTool)
            }
            guard let nativeTool = NativeMemoryNativeTool(upstreamTool: upstreamTool) else {
                return failure(toolName: upstreamTool.rawValue, code: .unsupportedTool)
            }

            switch nativeTool {
            case .recall:
                let request = try Self.decodeRecall(argumentsJSON)
                let normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedQuery.isEmpty,
                      normalizedQuery.count <= NativeMemoryToolRegistry.maximumQueryCharacters
                else {
                    return failure(
                        toolName: nativeTool.rawValue,
                        code: .invalidField,
                        fields: ["query"]
                    )
                }

                let depth = request.depth ?? 1
                guard (0...3).contains(depth) else {
                    return failure(
                        toolName: nativeTool.rawValue,
                        code: .invalidField,
                        fields: ["depth"]
                    )
                }

                try Task.checkCancellation()
                let recalled = try await memoryStore.recall(
                    projectID: projectID,
                    query: normalizedQuery,
                    options: LocalMemoryRecallOptions(
                        maximumHops: depth,
                        limit: NativeMemoryToolRegistry.maximumRecallResults
                    )
                )
                try Task.checkCancellation()

                let memories = recalled.map(Self.recallMemory)
                let payload = NativeMemoryRecallSuccess(
                    tool: nativeTool.rawValue,
                    retrieval: "local_token_anchor_cooccurrence",
                    depth: depth,
                    maximumResults: NativeMemoryToolRegistry.maximumRecallResults,
                    resultCount: memories.count,
                    memories: memories
                )
                return success(
                    toolName: nativeTool.rawValue,
                    responseJSON: Self.encode(payload),
                    completionSummary: "nmem_recall completed with \(memories.count) project-scoped result(s)"
                )

            case .show:
                let request = try Self.decodeShow(argumentsJSON)
                guard request.memoryID.count == 36,
                      let memoryID = UUID(uuidString: request.memoryID)
                else {
                    return failure(
                        toolName: nativeTool.rawValue,
                        code: .invalidMemoryID,
                        fields: ["memory_id"]
                    )
                }

                try Task.checkCancellation()
                // The store's export is already transactionally project-scoped.
                // This dispatcher filters it before serialization; it never returns
                // the raw export, anchors, provenance references, or another ID space.
                let export = try await memoryStore.exportProject(projectID)
                try Task.checkCancellation()
                guard let fact = export.facts.first(where: { $0.id == memoryID }) else {
                    // Missing and foreign IDs intentionally share one response so a
                    // model cannot probe whether another project owns an identifier.
                    return failure(toolName: nativeTool.rawValue, code: .memoryNotFound)
                }

                let allEdges = export.synapses.compactMap { synapse -> NativeMemoryShowSynapse? in
                    guard synapse.kind == .coOccurs else { return nil }
                    if synapse.sourceID == memoryID {
                        return NativeMemoryShowSynapse(
                            kind: "co_occurs",
                            memoryID: synapse.targetID.uuidString,
                            weight: synapse.weight,
                            createdAt: Self.iso8601(synapse.createdAt)
                        )
                    }
                    if synapse.targetID == memoryID {
                        return NativeMemoryShowSynapse(
                            kind: "co_occurs",
                            memoryID: synapse.sourceID.uuidString,
                            weight: synapse.weight,
                            createdAt: Self.iso8601(synapse.createdAt)
                        )
                    }
                    return nil
                }.sorted { lhs, rhs in
                    if lhs.memoryID != rhs.memoryID { return lhs.memoryID < rhs.memoryID }
                    return lhs.createdAt < rhs.createdAt
                }
                let visibleEdges = Array(allEdges.prefix(NativeMemoryToolRegistry.maximumShowSynapses))
                let payload = NativeMemoryShowSuccess(
                    tool: nativeTool.rawValue,
                    memoryID: fact.id.uuidString,
                    content: fact.content,
                    createdAt: Self.iso8601(fact.createdAt),
                    source: Self.source(from: fact.source),
                    synapseCount: allEdges.count,
                    synapsesTruncated: allEdges.count > visibleEdges.count,
                    synapses: visibleEdges
                )
                return success(
                    toolName: nativeTool.rawValue,
                    responseJSON: Self.encode(payload),
                    completionSummary: "nmem_show completed with one project-scoped approved memory"
                )
            }
        } catch is CancellationError {
            return failure(toolName: eventToolName, code: .cancelled)
        } catch let error as NativeMemoryToolInputFailure {
            return failure(
                toolName: eventToolName,
                code: error.code,
                fields: error.fields
            )
        } catch {
            // Do not leak local database locations, SQLite text, source metadata,
            // or error content to the provider or the run event ledger.
            return failure(toolName: eventToolName, code: .localReadFailed)
        }
    }

    private func success(
        toolName: String,
        responseJSON: String,
        completionSummary: String
    ) -> NativeMemoryToolDispatchResult {
        NativeMemoryToolDispatchResult(
            responseJSON: responseJSON,
            effects: [
                NativeMemoryToolRunEffect(
                    kind: "tool.selected",
                    summary: "\(toolName) selected for a project-scoped local read"
                ),
                NativeMemoryToolRunEffect(kind: "tool.completed", summary: completionSummary)
            ],
            succeeded: true
        )
    }

    private func failure(
        toolName: String,
        code: NativeMemoryToolErrorCode,
        fields: [String] = []
    ) -> NativeMemoryToolDispatchResult {
        let sortedFields = fields.sorted()
        let payload = NativeMemoryToolErrorResponse(
            tool: toolName,
            error: NativeMemoryToolErrorPayload(
                code: code,
                message: Self.message(for: code),
                fields: sortedFields
            )
        )
        return NativeMemoryToolDispatchResult(
            responseJSON: Self.encode(payload),
            effects: [
                NativeMemoryToolRunEffect(
                    kind: "tool.selected",
                    summary: "\(toolName) selected for a project-scoped local read"
                ),
                NativeMemoryToolRunEffect(
                    kind: "tool.failed",
                    summary: "\(toolName) failed: \(code.rawValue)"
                )
            ],
            succeeded: false
        )
    }

    private static func decodeRecall(_ argumentsJSON: String) throws -> NativeMemoryRecallToolRequest {
        let data = try validatedObject(
            from: argumentsJSON,
            allowedFields: ["query", "depth"],
            nullableOptionalFields: []
        )
        do {
            return try JSONDecoder().decode(NativeMemoryRecallToolRequest.self, from: data)
        } catch {
            throw NativeMemoryToolInputFailure.invalidField(["query", "depth"])
        }
    }

    private static func decodeShow(_ argumentsJSON: String) throws -> NativeMemoryShowToolRequest {
        let data = try validatedObject(
            from: argumentsJSON,
            allowedFields: ["memory_id"],
            nullableOptionalFields: []
        )
        do {
            return try JSONDecoder().decode(NativeMemoryShowToolRequest.self, from: data)
        } catch {
            throw NativeMemoryToolInputFailure.invalidField(["memory_id"])
        }
    }

    /// Performs only object-shape validation at the untyped JSON boundary. All
    /// values are immediately decoded into immutable Codable request structs.
    private static func validatedObject(
        from argumentsJSON: String,
        allowedFields: Set<String>,
        nullableOptionalFields: Set<String>
    ) throws -> Data {
        let data = Data(argumentsJSON.utf8)
        guard !data.isEmpty else { throw NativeMemoryToolInputFailure.invalidJSON }
        guard data.count <= 16_384 else { throw NativeMemoryToolInputFailure.invalidArguments }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw NativeMemoryToolInputFailure.invalidJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw NativeMemoryToolInputFailure.invalidArguments
        }

        let unsupported = Set(dictionary.keys).subtracting(allowedFields).sorted()
        guard unsupported.isEmpty else {
            throw NativeMemoryToolInputFailure.unsupportedField(unsupported)
        }

        let nullFields = dictionary.compactMap { key, value -> String? in
            value is NSNull && !nullableOptionalFields.contains(key) ? key : nil
        }.sorted()
        guard nullFields.isEmpty else {
            throw NativeMemoryToolInputFailure.invalidField(nullFields)
        }
        return data
    }

    private static func recallMemory(_ result: LocalMemoryRecallResult) -> NativeMemoryRecallMemory {
        let excerpt = excerpt(from: result.storedFact)
        return NativeMemoryRecallMemory(
            memoryID: result.id.uuidString,
            content: excerpt.content,
            contentTruncated: excerpt.truncated,
            createdAt: iso8601(result.fact.createdAt),
            source: source(from: result.source),
            score: result.score,
            matchedAnchors: result.matchedAnchors,
            hopCount: result.hopCount
        )
    }

    private static func source(from source: LocalMemorySource) -> NativeMemoryToolSource {
        // Free-form source labels and references can contain local paths or
        // accidentally entered secrets. The source category is sufficient for
        // this model-visible read result; audit/provenance remains local-only.
        NativeMemoryToolSource(kind: source.kind.rawValue)
    }

    private static func excerpt(from content: String) -> (content: String, truncated: Bool) {
        guard content.count > NativeMemoryToolRegistry.maximumRecallExcerptCharacters else {
            return (content, false)
        }
        return (
            String(content.prefix(NativeMemoryToolRegistry.maximumRecallExcerptCharacters)),
            true
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func encode<Payload: Encodable>(_ payload: Payload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return String(decoding: try encoder.encode(payload), as: UTF8.self)
        } catch {
            // Every payload above consists only of Codable primitives. This
            // fallback remains valid JSON if a future payload is accidentally
            // made non-encodable, while keeping the failure surface redacted.
            return #"{"ok":false,"tool":"native_memory_unavailable","error":{"code":"local_read_failed","message":"The approved local memory could not be read.","fields":[]}}"#
        }
    }

    private static func message(for code: NativeMemoryToolErrorCode) -> String {
        switch code {
        case .projectNotSelected:
            return "Select a project before sharing approved memory with a model."
        case .invalidProjectScope:
            return "The selected project scope is not a valid native project identity."
        case .projectMismatch:
            return "The requested project does not match the user-selected project."
        case .consentNotGranted:
            return "Sharing approved memory with this provider is not enabled for the selected project."
        case .unsupportedTool:
            return "This upstream memory tool is not implemented in the native iOS allowlist."
        case .unavailableTool:
            return "This tool is not available in the native iOS allowlist."
        case .invalidJSON:
            return "Tool arguments must be valid JSON."
        case .invalidArguments:
            return "Tool arguments must be one bounded JSON object."
        case .unsupportedField:
            return "One or more requested fields are unsupported by this native iOS subset."
        case .invalidField:
            return "One or more tool fields are invalid."
        case .invalidMemoryID:
            return "memory_id must be a UUID returned by native nmem_recall."
        case .memoryNotFound:
            return "No approved memory with that ID exists in the selected project."
        case .cancelled:
            return "The local memory read was cancelled."
        case .localReadFailed:
            return "The approved local memory could not be read."
        }
    }
}

private enum NativeMemoryToolInputFailure: Error {
    case invalidJSON
    case invalidArguments
    case unsupportedField([String])
    case invalidField([String])

    var code: NativeMemoryToolErrorCode {
        switch self {
        case .invalidJSON:
            return .invalidJSON
        case .invalidArguments:
            return .invalidArguments
        case .unsupportedField:
            return .unsupportedField
        case .invalidField:
            return .invalidField
        }
    }

    var fields: [String] {
        switch self {
        case .invalidJSON, .invalidArguments:
            return []
        case .unsupportedField(let fields), .invalidField(let fields):
            return fields.sorted()
        }
    }
}

private struct NativeMemoryToolSource: Encodable, Sendable, Hashable {
    let kind: String
}

private struct NativeMemoryRecallMemory: Encodable, Sendable, Hashable {
    let memoryID: String
    let content: String
    let contentTruncated: Bool
    let createdAt: String
    let source: NativeMemoryToolSource
    let score: Double
    let matchedAnchors: [String]
    let hopCount: Int

    enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id"
        case content
        case contentTruncated = "content_truncated"
        case createdAt = "created_at"
        case source
        case score
        case matchedAnchors = "matched_anchors"
        case hopCount = "hop_count"
    }
}

private struct NativeMemoryRecallSuccess: Encodable, Sendable, Hashable {
    let ok = true
    let tool: String
    let retrieval: String
    let depth: Int
    let maximumResults: Int
    let resultCount: Int
    let memories: [NativeMemoryRecallMemory]

    enum CodingKeys: String, CodingKey {
        case ok
        case tool
        case retrieval
        case depth
        case maximumResults = "maximum_results"
        case resultCount = "result_count"
        case memories
    }
}

private struct NativeMemoryShowSynapse: Encodable, Sendable, Hashable {
    let kind: String
    let memoryID: String
    let weight: Double
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind
        case memoryID = "memory_id"
        case weight
        case createdAt = "created_at"
    }
}

private struct NativeMemoryShowSuccess: Encodable, Sendable, Hashable {
    let ok = true
    let tool: String
    let memoryID: String
    let content: String
    let createdAt: String
    let source: NativeMemoryToolSource
    let synapseCount: Int
    let synapsesTruncated: Bool
    let synapses: [NativeMemoryShowSynapse]

    enum CodingKeys: String, CodingKey {
        case ok
        case tool
        case memoryID = "memory_id"
        case content
        case createdAt = "created_at"
        case source
        case synapseCount = "synapse_count"
        case synapsesTruncated = "synapses_truncated"
        case synapses
    }
}

private struct NativeMemoryToolErrorPayload: Encodable, Sendable, Hashable {
    let code: NativeMemoryToolErrorCode
    let message: String
    let fields: [String]
}

private struct NativeMemoryToolErrorResponse: Encodable, Sendable, Hashable {
    let ok = false
    let tool: String
    let error: NativeMemoryToolErrorPayload
}
