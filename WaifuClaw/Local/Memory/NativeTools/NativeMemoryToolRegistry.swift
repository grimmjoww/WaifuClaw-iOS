import Foundation

/// Immutable native-memory allowlist. It intentionally does not mirror the
/// upstream server's tools/list behavior: the iOS app advertises only handlers
/// that exist locally and pass the per-project sharing gate at this moment.
enum NativeMemoryToolRegistry {
    static let maximumQueryCharacters = 4_000
    static let maximumRecallResults = 12
    static let maximumRecallExcerptCharacters = 2_000
    static let maximumShowSynapses = 64

    private static let nativeAllowlist: [NativeMemoryNativeTool] = [.recall, .show]

    private static let definitionsByTool: [NativeMemoryNativeTool: AgentToolDefinition] = [
        .recall: AgentToolDefinition(
            name: NativeMemoryNativeTool.recall.rawValue,
            description: "Read only approved memory in the currently user-selected project. Native iOS subset: query plus local graph depth 0...3 only; returns at most 12 project-scoped excerpts. It never writes, exports storage, accesses other projects, or uses a network. All other upstream nmem_recall fields, modes, compact, and token_budget are rejected.",
            parametersJSON: Data(#"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":4000,"description":"Memory query for the selected project."},"depth":{"type":"integer","minimum":0,"maximum":3,"description":"Native local graph-hop depth. This is not upstream spreading-activation depth parity."}},"required":["query"],"additionalProperties":false}"#.utf8)
        ),
        .show: AgentToolDefinition(
            name: NativeMemoryNativeTool.show.rawValue,
            description: "Read one approved local fact by its UUID in the currently user-selected project. Returns verbatim approved fact content and bounded same-project co-occurrence edges only. It never writes, exports raw storage, accesses other projects, or uses a network. Upstream fiber/neuron aliases, compact, and token_budget are rejected.",
            parametersJSON: Data(#"{"type":"object","properties":{"memory_id":{"type":"string","minLength":36,"maxLength":36,"pattern":"^[0-9A-Fa-f-]{36}$","description":"UUID returned by this native nmem_recall result."}},"required":["memory_id"],"additionalProperties":false}"#.utf8)
        )
    ]

    /// Returns the exact two `AgentToolDefinition`s only when the caller has a
    /// canonical user-selected project, requested that same project, and the
    /// user enabled sharing approved memory with this provider for that project.
    static func definitions(for access: NativeMemoryToolAccessContext) -> [AgentToolDefinition] {
        guard case .available = availability(for: access) else { return [] }
        return nativeAllowlist.compactMap { definitionsByTool[$0] }
    }

    /// The source-audited 63-name vocabulary is exposed only for classification
    /// of rejected calls and future work; it is never a list of advertised tools.
    static var upstreamToolCount: Int {
        NativeMemoryUpstreamTool.allCases.count
    }

    static func isNativelySupported(_ upstreamTool: NativeMemoryUpstreamTool) -> Bool {
        NativeMemoryNativeTool(upstreamTool: upstreamTool) != nil
    }

    static func availability(for access: NativeMemoryToolAccessContext) -> NativeMemoryToolAvailability {
        guard let selectedProjectID = access.selectedProjectID,
              !selectedProjectID.isEmpty
        else {
            return .unavailable(.projectNotSelected)
        }
        guard isCanonicalProjectID(selectedProjectID) else {
            return .unavailable(.invalidProjectScope)
        }
        guard access.requestedProjectID == selectedProjectID else {
            return .unavailable(.projectMismatch)
        }
        guard access.hasModelSharingConsent else {
            return .unavailable(.consentNotGranted)
        }
        return .available(projectID: selectedProjectID)
    }

    private static func isCanonicalProjectID(_ projectID: String) -> Bool {
        projectID.count == 64 && projectID.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
