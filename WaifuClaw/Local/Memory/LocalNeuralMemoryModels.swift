import Foundation

/// The origin category shown with every locally stored memory.
public enum LocalMemorySourceKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// A fact typed directly into the memory UI.
    case manualNote
    /// A fact proposed from a conversation and explicitly approved by the user.
    case conversation
    /// A fact imported from a user-selected local document and explicitly approved.
    case localDocument
    /// A fact proposed by the local agent and explicitly approved by the user.
    case agentProposal
}

/// Human-readable source information retained with a stored fact.
///
/// `reference` is local-only metadata such as a conversation message ID or a
/// user-selected document name. Do not put credentials, URLs requiring auth, or
/// private file contents here.
public struct LocalMemorySource: Codable, Sendable, Hashable {
    public let kind: LocalMemorySourceKind
    public let label: String
    public let reference: String?

    public init(kind: LocalMemorySourceKind, label: String, reference: String? = nil) {
        self.kind = kind
        self.label = label
        self.reference = reference
    }
}

/// Audit information supplied by the UI or agent integration at approval time.
public struct LocalMemoryProvenance: Codable, Sendable, Hashable {
    /// Stable local actor identifier, for example `user`, `conversation-ui`, or `native-agent`.
    public let capturedBy: String
    /// Optional local record that led to the proposal, such as a message UUID.
    public let sourceRecordID: String?
    /// Optional explanation entered by the approving user.
    public let approvalNote: String?

    public init(
        capturedBy: String,
        sourceRecordID: String? = nil,
        approvalNote: String? = nil
    ) {
        self.capturedBy = capturedBy
        self.sourceRecordID = sourceRecordID
        self.approvalNote = approvalNote
    }
}

/// A deliberately required acknowledgement for every write.
///
/// There is no unapproved case and no convenience method that silently captures
/// chat, agent, or document content. Callers must visibly pass `.userApproved`
/// only after a user has approved the specific request.
public enum LocalMemoryCaptureApproval: String, Codable, Sendable, Hashable {
    case userApproved
}

/// Input to the only production write API, `LocalNeuralMemoryStore.capture`.
public struct LocalMemoryCaptureRequest: Sendable, Hashable {
    public let projectID: String
    public let fact: String
    public let source: LocalMemorySource
    public let provenance: LocalMemoryProvenance

    public init(
        projectID: String,
        fact: String,
        source: LocalMemorySource,
        provenance: LocalMemoryProvenance
    ) {
        self.projectID = projectID
        self.fact = fact
        self.source = source
        self.provenance = provenance
    }
}

/// An immutable user-approved fact neuron stored in the local SQLite graph.
public struct LocalMemoryFact: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let projectID: String
    public let content: String
    public let source: LocalMemorySource
    public let provenance: LocalMemoryProvenance
    public let createdAt: Date

    public init(
        id: UUID,
        projectID: String,
        content: String,
        source: LocalMemorySource,
        provenance: LocalMemoryProvenance,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.content = content
        self.source = source
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

/// A deterministic keyword/token anchor neuron in one project namespace.
public struct LocalMemoryAnchor: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let projectID: String
    public let token: String
    public let createdAt: Date

    public init(id: UUID, projectID: String, token: String, createdAt: Date) {
        self.id = id
        self.projectID = projectID
        self.token = token
        self.createdAt = createdAt
    }
}

/// The two locally supported graph edge types.
public enum LocalMemorySynapseKind: String, Codable, Sendable, Hashable {
    /// Directed membership edge from a fact neuron to one keyword anchor.
    case factContainsAnchor
    /// Undirected, weighted relation between facts that share keyword anchors.
    case coOccurs
}

/// A graph edge included in a local JSON export.
public struct LocalMemorySynapse: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let projectID: String
    public let sourceID: UUID
    public let targetID: UUID
    public let kind: LocalMemorySynapseKind
    /// Always clamped to the inclusive range 0...1.
    public let weight: Double
    public let createdAt: Date

    public init(
        id: String,
        projectID: String,
        sourceID: UUID,
        targetID: UUID,
        kind: LocalMemorySynapseKind,
        weight: Double,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.weight = weight
        self.createdAt = createdAt
    }
}

/// Options for bounded deterministic spreading activation during recall.
public struct LocalMemoryRecallOptions: Sendable, Hashable {
    /// Number of fact-to-fact co-occurrence hops after direct anchor matches.
    public var maximumHops: Int
    /// Multiplicative attenuation applied at every fact-to-fact hop.
    public var decay: Double
    /// Activations below this value are not traversed or returned by graph spread.
    public var minimumScore: Double
    /// Maximum number of ranked facts returned to the caller.
    public var limit: Int

    public init(
        maximumHops: Int = 2,
        decay: Double = 0.55,
        minimumScore: Double = 0.04,
        limit: Int = 12
    ) {
        self.maximumHops = maximumHops
        self.decay = decay
        self.minimumScore = minimumScore
        self.limit = limit
    }
}

/// A ranked recall result with enough evidence for a UI or agent to explain it.
public struct LocalMemoryRecallResult: Codable, Identifiable, Sendable, Hashable {
    public let fact: LocalMemoryFact
    /// Repeated explicitly so integrations do not have to infer provenance from a score.
    public let source: LocalMemorySource
    /// Bounded activation score in the inclusive range 0...1.
    public let score: Double
    public let matchedAnchors: [String]
    /// Zero is a direct query-anchor match; positive values were reached by spreading activation.
    public let hopCount: Int
    /// Deterministic, user-displayable retrieval explanation.
    public let why: String

    public var id: UUID { fact.id }
    public var storedFact: String { fact.content }

    public init(
        fact: LocalMemoryFact,
        source: LocalMemorySource,
        score: Double,
        matchedAnchors: [String],
        hopCount: Int,
        why: String
    ) {
        self.fact = fact
        self.source = source
        self.score = score
        self.matchedAnchors = matchedAnchors
        self.hopCount = hopCount
        self.why = why
    }
}

/// Portable, local-only JSON payload for one isolated project graph.
public struct LocalMemoryExport: Codable, Sendable, Hashable {
    public let formatVersion: Int
    public let projectID: String
    public let exportedAt: Date
    public let facts: [LocalMemoryFact]
    public let anchors: [LocalMemoryAnchor]
    public let synapses: [LocalMemorySynapse]

    public init(
        formatVersion: Int,
        projectID: String,
        exportedAt: Date,
        facts: [LocalMemoryFact],
        anchors: [LocalMemoryAnchor],
        synapses: [LocalMemorySynapse]
    ) {
        self.formatVersion = formatVersion
        self.projectID = projectID
        self.exportedAt = exportedAt
        self.facts = facts
        self.anchors = anchors
        self.synapses = synapses
    }
}

/// Hard caps used to keep the on-device graph predictably bounded.
public struct LocalNeuralMemoryConfiguration: Sendable, Hashable {
    public var maximumFactsPerProject: Int
    public var maximumAnchorsPerFact: Int
    public var maximumExpansionNodes: Int

    public init(
        maximumFactsPerProject: Int = 2_000,
        maximumAnchorsPerFact: Int = 24,
        maximumExpansionNodes: Int = 256
    ) {
        self.maximumFactsPerProject = maximumFactsPerProject
        self.maximumAnchorsPerFact = maximumAnchorsPerFact
        self.maximumExpansionNodes = maximumExpansionNodes
    }
}

/// Errors emitted by the local graph store. No network errors are possible: it never calls a remote service.
public enum LocalNeuralMemoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidDatabaseURL(String)
    case applicationSupportUnavailable
    case incompatibleSchemaVersion(found: Int, supported: Int)
    case sqlite(code: Int32, message: String)
    case invalidProjectID
    case invalidFact
    case invalidSource
    case invalidProvenance
    case projectCapacityReached(projectID: String, maximum: Int)
    case memoryNotFound(id: UUID, projectID: String)
    case corruptData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL(let value):
            return "The database URL is not a file URL: \(value)"
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .incompatibleSchemaVersion(let found, let supported):
            return "Memory schema version \(found) is newer than supported version \(supported)."
        case .sqlite(let code, let message):
            return "SQLite error \(code): \(message)"
        case .invalidProjectID:
            return "A non-empty project ID of at most 128 characters is required."
        case .invalidFact:
            return "A fact with searchable content of at most 10,000 characters is required."
        case .invalidSource:
            return "A human-readable memory source label is required."
        case .invalidProvenance:
            return "A non-empty provenance capturedBy value is required."
        case .projectCapacityReached(let projectID, let maximum):
            return "Project \(projectID) already has the maximum \(maximum) approved memories."
        case .memoryNotFound(let id, let projectID):
            return "Memory \(id.uuidString) was not found in project \(projectID)."
        case .corruptData(let description):
            return "The local memory database contains invalid data: \(description)"
        }
    }
}
