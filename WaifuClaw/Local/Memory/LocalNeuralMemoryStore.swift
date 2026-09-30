import Foundation
import SQLite3

private let localMemorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct LocalMemoryDirectEvidence {
    var fact: LocalMemoryFact
    var anchorWeights: [String: Double]
}

private struct LocalMemoryActivation {
    let factID: UUID
    var score: Double
    var matchedAnchors: [String]
    var hopCount: Int
    var why: String
    var path: [UUID]
}

/// Actor-isolated, SQLite-backed memory graph for explicit user-approved facts.
///
/// Each fact is a fact-neuron. Deterministic token/keyword anchor-neurons and
/// fact-to-fact co-occurrence synapses are generated within the same transaction.
/// Every table and lookup includes `project_id`; there is no cross-project query,
/// shared anchor, remote call, model invocation, or credential storage.
///
/// Typical integration:
///
/// ```swift
/// let store = try LocalNeuralMemoryStore()
/// let fact = try await store.capture(request, approval: .userApproved)
/// let results = try await store.recall(projectID: fact.projectID, query: "tea preference")
/// ```
public actor LocalNeuralMemoryStore {
    private static let schemaVersion = 1
    private static let exportFormatVersion = 1
    private static let maximumSupportedHops = 4
    private static let maximumResultLimit = 100
    private static let maximumFactCharacters = 10_000
    private static let maximumProjectIDCharacters = 128
    private static let maximumSourceLabelCharacters = 512
    private static let maximumProvenanceCharacters = 512

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for",
        "from", "has", "have", "he", "her", "him", "i", "in", "is", "it", "its",
        "me", "my", "of", "on", "or", "our", "she", "that", "the", "their", "them",
        "there", "these", "they", "this", "to", "us", "was", "we", "were", "with",
        "you", "your"
    ]

    private var database: OpaquePointer?
    private let configuration: LocalNeuralMemoryConfiguration

    /// Opens an isolated local graph database, creating it and its schema if needed.
    /// Pass an explicit file URL in tests or when a host app owns storage placement.
    public init(
        databaseURL: URL? = nil,
        configuration: LocalNeuralMemoryConfiguration = LocalNeuralMemoryConfiguration()
    ) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        guard resolvedURL.isFileURL else {
            throw LocalNeuralMemoryError.invalidDatabaseURL(resolvedURL.absoluteString)
        }

        self.configuration = Self.normalized(configuration)
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try NativeDatabaseProtection.prepareDirectory(resolvedURL.deletingLastPathComponent())

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            resolvedURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard openResult == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open database."
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw LocalNeuralMemoryError.sqlite(code: openResult, message: message)
        }

        database = openedDatabase
        do {
            try configureConnection()
            try migrateIfNeeded()
            try NativeDatabaseProtection.protectExistingFiles(at: resolvedURL)
        } catch {
            sqlite3_close_v2(openedDatabase)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// Stores exactly one approved fact and updates its local graph edges atomically.
    ///
    /// This is intentionally the only production write method. A caller must pass
    /// `.userApproved` for the specific request; there is no auto-capture path for
    /// agent output, chat history, or files.
    @discardableResult
    public func capture(
        _ request: LocalMemoryCaptureRequest,
        approval: LocalMemoryCaptureApproval
    ) throws -> LocalMemoryFact {
        // Keep the acknowledgement in the call shape even though it currently has one valid case.
        guard approval == .userApproved else { throw LocalNeuralMemoryError.invalidProvenance }

        let projectID = try Self.validProjectID(request.projectID)
        let content = try Self.validFact(request.fact)
        let source = try Self.validSource(request.source)
        let provenance = try Self.validProvenance(request.provenance)
        let tokenCounts = anchorTokenCounts(for: content)
        guard !tokenCounts.isEmpty else { throw LocalNeuralMemoryError.invalidFact }

        let createdAt = Date()
        let fact = LocalMemoryFact(
            id: UUID(),
            projectID: projectID,
            content: content,
            source: source,
            provenance: provenance,
            createdAt: createdAt
        )

        return try inTransaction {
            let count = try factCount(in: projectID)
            guard count < configuration.maximumFactsPerProject else {
                throw LocalNeuralMemoryError.projectCapacityReached(
                    projectID: projectID,
                    maximum: configuration.maximumFactsPerProject
                )
            }

            try insert(fact)

            let maximumFrequency = max(tokenCounts.map { $0.count }.max() ?? 1, 1)
            var anchorIDs: [UUID] = []
            anchorIDs.reserveCapacity(tokenCounts.count)
            for tokenCount in tokenCounts {
                let anchorID = try findOrCreateAnchor(
                    token: tokenCount.token,
                    projectID: projectID,
                    createdAt: createdAt
                )
                anchorIDs.append(anchorID)
                let anchorWeight = Self.clamp(
                    0.6 + 0.4 * Double(tokenCount.count) / Double(maximumFrequency),
                    lower: 0,
                    upper: 1
                )
                try insertFactAnchorSynapse(
                    factID: fact.id,
                    anchorID: anchorID,
                    projectID: projectID,
                    weight: anchorWeight,
                    createdAt: createdAt
                )
            }

            // Co-occurrence is a cosine-style weight over the deterministic anchor sets.
            // The pair is canonicalized, so it is one undirected synapse rather than two.
            let candidates = try factSharedAnchorCounts(
                projectID: projectID,
                anchorIDs: anchorIDs,
                excluding: fact.id
            )
            for candidate in candidates {
                let otherAnchorCount = try anchorCount(forFactID: candidate.factID, projectID: projectID)
                guard otherAnchorCount > 0 else { continue }
                let weight = Self.clamp(
                    Double(candidate.sharedCount) /
                        sqrt(Double(anchorIDs.count) * Double(otherAnchorCount)),
                    lower: 0.05,
                    upper: 1
                )
                try upsertCooccurrenceSynapse(
                    firstFactID: fact.id,
                    secondFactID: candidate.factID,
                    projectID: projectID,
                    weight: weight,
                    createdAt: createdAt
                )
            }

            return fact
        }
    }

    /// Lists approved fact-neurons for exactly one project in stable creation order.
    public func memories(in projectID: String) throws -> [LocalMemoryFact] {
        let projectID = try Self.validProjectID(projectID)
        return try withStatement(
            """
            SELECT id, project_id, content, source_json, provenance_json, created_at
            FROM memory_neurons
            WHERE project_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            var facts: [LocalMemoryFact] = []
            while try stepToRowOrDone(statement) {
                facts.append(try decodeFact(statement))
            }
            return facts
        }
    }

    /// Recalls facts using query anchors followed by bounded weighted graph spreading.
    ///
    /// Direct anchor matches start at hop 0. Each co-occurrence hop multiplies the
    /// current activation by `decay * synapse.weight`; only a stronger route replaces
    /// an existing activation. Stable score, hop, timestamp, and UUID tie-breakers
    /// make the result deterministic for an unchanged database and query.
    public func recall(
        projectID rawProjectID: String,
        query rawQuery: String,
        options rawOptions: LocalMemoryRecallOptions = LocalMemoryRecallOptions()
    ) throws -> [LocalMemoryRecallResult] {
        let projectID = try Self.validProjectID(rawProjectID)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let queryTokens = anchorTokenCounts(for: query).map { $0.token }
        guard !queryTokens.isEmpty else { return [] }
        let options = normalized(rawOptions)

        let allFacts = try memories(in: projectID)
        let factsByID = Dictionary(uniqueKeysWithValues: allFacts.map { ($0.id, $0) })
        guard !factsByID.isEmpty else { return [] }

        let directEvidence = try directAnchorEvidence(projectID: projectID, queryTokens: queryTokens)
        guard !directEvidence.isEmpty else { return [] }

        var activations: [UUID: LocalMemoryActivation] = [:]
        for evidence in directEvidence.values {
            let matchedAnchors = evidence.anchorWeights.keys.sorted()
            let score = Self.clamp(
                matchedAnchors.reduce(0) { partial, anchor in
                    partial + (evidence.anchorWeights[anchor] ?? 0)
                } / Double(queryTokens.count),
                lower: 0,
                upper: 1
            )
            activations[evidence.fact.id] = LocalMemoryActivation(
                factID: evidence.fact.id,
                score: score,
                matchedAnchors: matchedAnchors,
                hopCount: 0,
                why: "Direct anchor match: \(matchedAnchors.joined(separator: ", ")).",
                path: [evidence.fact.id]
            )
        }

        // The active frontier and the number of newly discovered facts are both capped.
        // Direct matches remain eligible for output even if there are more than the cap.
        var frontier = ordered(Array(activations.values))
        if frontier.count > configuration.maximumExpansionNodes {
            frontier = Array(frontier.prefix(configuration.maximumExpansionNodes))
        }
        var newlyDiscovered = Set(frontier.map(\.factID))

        guard options.maximumHops > 0 else {
            return rankedResults(from: activations, factsByID: factsByID, limit: options.limit)
        }

        for nextHop in 1...options.maximumHops {
            guard !frontier.isEmpty else { break }
            var nextFrontier: [LocalMemoryActivation] = []

            for current in ordered(frontier) {
                let neighbors = try cooccurrenceNeighbors(
                    forFactID: current.factID,
                    projectID: projectID
                )
                for neighbor in neighbors {
                    guard factsByID[neighbor.factID] != nil,
                          !current.path.contains(neighbor.factID)
                    else { continue }

                    let propagatedScore = Self.clamp(
                        current.score * options.decay * neighbor.weight,
                        lower: 0,
                        upper: 1
                    )
                    guard propagatedScore >= options.minimumScore else { continue }

                    let previous = activations[neighbor.factID]
                    guard previous == nil || propagatedScore > previous!.score + 0.000_000_1 else {
                        continue
                    }

                    // Never allow an unbounded number of *new* graph nodes. Updating an
                    // already found node consumes no additional graph capacity.
                    if previous == nil,
                       newlyDiscovered.count >= configuration.maximumExpansionNodes {
                        continue
                    }

                    let inheritedAnchors = current.matchedAnchors
                    let activation = LocalMemoryActivation(
                        factID: neighbor.factID,
                        score: propagatedScore,
                        matchedAnchors: inheritedAnchors,
                        hopCount: nextHop,
                        why: "Spreading activation hop \(nextHop) from \(current.factID.uuidString) through co-occurs (weight \(Self.scoreText(neighbor.weight))).",
                        path: current.path + [neighbor.factID]
                    )
                    activations[neighbor.factID] = activation
                    nextFrontier.append(activation)
                    newlyDiscovered.insert(neighbor.factID)
                }
            }

            frontier = ordered(nextFrontier)
            if frontier.count > configuration.maximumExpansionNodes {
                frontier = Array(frontier.prefix(configuration.maximumExpansionNodes))
            }
        }

        return rankedResults(from: activations, factsByID: factsByID, limit: options.limit)
    }

    /// Deletes one fact-neuron only within the supplied project namespace.
    /// Associated anchor and co-occurrence synapses cascade in the same transaction.
    public func deleteMemory(id: UUID, projectID rawProjectID: String) throws {
        let projectID = try Self.validProjectID(rawProjectID)
        try inTransaction {
            try withStatement(
                "DELETE FROM memory_neurons WHERE id = ? AND project_id = ?;"
            ) { statement in
                try bind(id, to: statement, at: 1)
                try bind(projectID, to: statement, at: 2)
                try stepToDone(statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw LocalNeuralMemoryError.memoryNotFound(id: id, projectID: projectID)
            }
            try deleteOrphanedAnchors(in: projectID)
        }
    }

    /// Permanently removes every fact, anchor, and synapse owned by one project.
    /// It is intentionally idempotent so a UI can safely retry a confirmed purge.
    public func purgeProject(_ rawProjectID: String) throws {
        let projectID = try Self.validProjectID(rawProjectID)
        try inTransaction {
            try withStatement("DELETE FROM memory_neurons WHERE project_id = ?;") { statement in
                try bind(projectID, to: statement, at: 1)
                try stepToDone(statement)
            }
            try withStatement("DELETE FROM anchor_neurons WHERE project_id = ?;") { statement in
                try bind(projectID, to: statement, at: 1)
                try stepToDone(statement)
            }
        }
    }

    /// Exports only one project's locally stored graph; no credentials or other projects are included.
    public func exportProject(
        _ rawProjectID: String,
        exportedAt: Date = Date()
    ) throws -> LocalMemoryExport {
        let projectID = try Self.validProjectID(rawProjectID)
        let facts = try memories(in: projectID)
        let anchors = try anchors(in: projectID)
        let synapses = try synapses(in: projectID)
        return LocalMemoryExport(
            formatVersion: Self.exportFormatVersion,
            projectID: projectID,
            exportedAt: exportedAt,
            facts: facts,
            anchors: anchors,
            synapses: synapses
        )
    }

    /// Produces deterministic-key-order, ISO-8601 local JSON suitable for user-directed export.
    public func exportJSON(
        forProject rawProjectID: String,
        exportedAt: Date = Date()
    ) throws -> Data {
        let export = try exportProject(rawProjectID, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }

    private static func normalized(
        _ configuration: LocalNeuralMemoryConfiguration
    ) -> LocalNeuralMemoryConfiguration {
        LocalNeuralMemoryConfiguration(
            maximumFactsPerProject: min(max(configuration.maximumFactsPerProject, 1), 10_000),
            maximumAnchorsPerFact: min(max(configuration.maximumAnchorsPerFact, 1), 64),
            maximumExpansionNodes: min(max(configuration.maximumExpansionNodes, 1), 1_024)
        )
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalNeuralMemoryError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent("WaifuClaw", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("LocalNeuralMemory.sqlite", isDirectory: false)
    }

    private func configureConnection() throws {
        try executeAndDiscardRows("PRAGMA foreign_keys = ON;")
        try executeAndDiscardRows("PRAGMA journal_mode = WAL;")
        try executeAndDiscardRows("PRAGMA synchronous = NORMAL;")
        try executeAndDiscardRows("PRAGMA busy_timeout = 5000;")
    }

    private func migrateIfNeeded() throws {
        let currentVersion = try userVersion()
        guard currentVersion >= 0 else {
            throw LocalNeuralMemoryError.corruptData("PRAGMA user_version is negative")
        }
        guard currentVersion <= Self.schemaVersion else {
            throw LocalNeuralMemoryError.incompatibleSchemaVersion(
                found: currentVersion,
                supported: Self.schemaVersion
            )
        }
        guard currentVersion == 0 else { return }

        try inTransaction {
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS memory_neurons (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source_json BLOB NOT NULL,
                    provenance_json BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE (project_id, id)
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS anchor_neurons (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    token TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE (project_id, id),
                    UNIQUE (project_id, token)
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS fact_anchor_synapses (
                    project_id TEXT NOT NULL,
                    fact_id TEXT NOT NULL,
                    anchor_id TEXT NOT NULL,
                    weight REAL NOT NULL CHECK (weight >= 0.0 AND weight <= 1.0),
                    created_at REAL NOT NULL,
                    PRIMARY KEY (project_id, fact_id, anchor_id),
                    FOREIGN KEY (project_id, fact_id)
                        REFERENCES memory_neurons(project_id, id) ON DELETE CASCADE,
                    FOREIGN KEY (project_id, anchor_id)
                        REFERENCES anchor_neurons(project_id, id) ON DELETE CASCADE
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS cooccurrence_synapses (
                    project_id TEXT NOT NULL,
                    lower_fact_id TEXT NOT NULL,
                    upper_fact_id TEXT NOT NULL,
                    weight REAL NOT NULL CHECK (weight >= 0.0 AND weight <= 1.0),
                    created_at REAL NOT NULL,
                    PRIMARY KEY (project_id, lower_fact_id, upper_fact_id),
                    CHECK (lower_fact_id < upper_fact_id),
                    FOREIGN KEY (project_id, lower_fact_id)
                        REFERENCES memory_neurons(project_id, id) ON DELETE CASCADE,
                    FOREIGN KEY (project_id, upper_fact_id)
                        REFERENCES memory_neurons(project_id, id) ON DELETE CASCADE
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS memory_neurons_project_created_idx
                ON memory_neurons(project_id, created_at, id);
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS fact_anchor_synapses_project_anchor_idx
                ON fact_anchor_synapses(project_id, anchor_id, fact_id);
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS cooccurrence_synapses_project_lower_idx
                ON cooccurrence_synapses(project_id, lower_fact_id);
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS cooccurrence_synapses_project_upper_idx
                ON cooccurrence_synapses(project_id, upper_fact_id);
                """
            )
            try executeAndDiscardRows("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private func userVersion() throws -> Int {
        try withStatement("PRAGMA user_version;") { statement in
            guard try stepToRowOrDone(statement) else {
                throw LocalNeuralMemoryError.corruptData("PRAGMA user_version returned no row")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func insert(_ fact: LocalMemoryFact) throws {
        let sourceData = try JSONEncoder().encode(fact.source)
        let provenanceData = try JSONEncoder().encode(fact.provenance)
        try withStatement(
            """
            INSERT INTO memory_neurons
                (id, project_id, content, source_json, provenance_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        ) { statement in
            try bind(fact.id, to: statement, at: 1)
            try bind(fact.projectID, to: statement, at: 2)
            try bind(fact.content, to: statement, at: 3)
            try bind(sourceData, to: statement, at: 4)
            try bind(provenanceData, to: statement, at: 5)
            try bind(fact.createdAt, to: statement, at: 6)
            try stepToDone(statement)
        }
    }

    private func factCount(in projectID: String) throws -> Int {
        try withStatement(
            "SELECT COUNT(*) FROM memory_neurons WHERE project_id = ?;"
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            guard try stepToRowOrDone(statement) else {
                throw LocalNeuralMemoryError.corruptData("fact count returned no row")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func findOrCreateAnchor(
        token: String,
        projectID: String,
        createdAt: Date
    ) throws -> UUID {
        let existing = try withStatement(
            "SELECT id FROM anchor_neurons WHERE project_id = ? AND token = ?;"
        ) { statement -> UUID? in
            try bind(projectID, to: statement, at: 1)
            try bind(token, to: statement, at: 2)
            guard try stepToRowOrDone(statement) else { return nil }
            return try uuid(from: statement, at: 0, name: "anchor_neurons.id")
        }
        if let existing { return existing }

        let id = UUID()
        try withStatement(
            "INSERT INTO anchor_neurons (id, project_id, token, created_at) VALUES (?, ?, ?, ?);"
        ) { statement in
            try bind(id, to: statement, at: 1)
            try bind(projectID, to: statement, at: 2)
            try bind(token, to: statement, at: 3)
            try bind(createdAt, to: statement, at: 4)
            try stepToDone(statement)
        }
        return id
    }

    private func insertFactAnchorSynapse(
        factID: UUID,
        anchorID: UUID,
        projectID: String,
        weight: Double,
        createdAt: Date
    ) throws {
        try withStatement(
            """
            INSERT INTO fact_anchor_synapses (project_id, fact_id, anchor_id, weight, created_at)
            VALUES (?, ?, ?, ?, ?);
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            try bind(factID, to: statement, at: 2)
            try bind(anchorID, to: statement, at: 3)
            try bind(weight, to: statement, at: 4)
            try bind(createdAt, to: statement, at: 5)
            try stepToDone(statement)
        }
    }

    private func factSharedAnchorCounts(
        projectID: String,
        anchorIDs: [UUID],
        excluding factID: UUID
    ) throws -> [(factID: UUID, sharedCount: Int)] {
        guard !anchorIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: anchorIDs.count).joined(separator: ", ")
        let sql = """
            SELECT fact_id, COUNT(*)
            FROM fact_anchor_synapses
            WHERE project_id = ? AND anchor_id IN (\(placeholders)) AND fact_id != ?
            GROUP BY fact_id
            ORDER BY fact_id ASC;
            """
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            try bind(projectID, to: statement, at: index)
            index += 1
            for anchorID in anchorIDs {
                try bind(anchorID, to: statement, at: index)
                index += 1
            }
            try bind(factID, to: statement, at: index)

            var rows: [(factID: UUID, sharedCount: Int)] = []
            while try stepToRowOrDone(statement) {
                rows.append((
                    factID: try uuid(from: statement, at: 0, name: "fact_anchor_synapses.fact_id"),
                    sharedCount: Int(sqlite3_column_int64(statement, 1))
                ))
            }
            return rows
        }
    }

    private func anchorCount(forFactID factID: UUID, projectID: String) throws -> Int {
        try withStatement(
            "SELECT COUNT(*) FROM fact_anchor_synapses WHERE project_id = ? AND fact_id = ?;"
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            try bind(factID, to: statement, at: 2)
            guard try stepToRowOrDone(statement) else {
                throw LocalNeuralMemoryError.corruptData("anchor count returned no row")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func upsertCooccurrenceSynapse(
        firstFactID: UUID,
        secondFactID: UUID,
        projectID: String,
        weight: Double,
        createdAt: Date
    ) throws {
        let orderedIDs = [firstFactID, secondFactID].sorted { $0.uuidString < $1.uuidString }
        try withStatement(
            """
            INSERT INTO cooccurrence_synapses
                (project_id, lower_fact_id, upper_fact_id, weight, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(project_id, lower_fact_id, upper_fact_id)
            DO UPDATE SET weight = excluded.weight;
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            try bind(orderedIDs[0], to: statement, at: 2)
            try bind(orderedIDs[1], to: statement, at: 3)
            try bind(weight, to: statement, at: 4)
            try bind(createdAt, to: statement, at: 5)
            try stepToDone(statement)
        }
    }

    private func directAnchorEvidence(
        projectID: String,
        queryTokens: [String]
    ) throws -> [UUID: LocalMemoryDirectEvidence] {
        guard !queryTokens.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: queryTokens.count).joined(separator: ", ")
        let sql = """
            SELECT f.id, f.project_id, f.content, f.source_json, f.provenance_json, f.created_at,
                   a.token, s.weight
            FROM memory_neurons AS f
            JOIN fact_anchor_synapses AS s
              ON s.project_id = f.project_id AND s.fact_id = f.id
            JOIN anchor_neurons AS a
              ON a.project_id = s.project_id AND a.id = s.anchor_id
            WHERE f.project_id = ? AND a.token IN (\(placeholders))
            ORDER BY f.id ASC, a.token ASC;
            """
        return try withStatement(sql) { statement in
            try bind(projectID, to: statement, at: 1)
            for (offset, token) in queryTokens.enumerated() {
                try bind(token, to: statement, at: Int32(offset + 2))
            }

            var result: [UUID: LocalMemoryDirectEvidence] = [:]
            while try stepToRowOrDone(statement) {
                let fact = try decodeFact(statement)
                let token = try requiredString(from: statement, at: 6, name: "anchor_neurons.token")
                let weight = sqlite3_column_double(statement, 7)
                var evidence = result[fact.id] ?? LocalMemoryDirectEvidence(
                    fact: fact,
                    anchorWeights: [:]
                )
                evidence.anchorWeights[token] = max(evidence.anchorWeights[token] ?? 0, weight)
                result[fact.id] = evidence
            }
            return result
        }
    }

    private func cooccurrenceNeighbors(
        forFactID factID: UUID,
        projectID: String
    ) throws -> [(factID: UUID, weight: Double)] {
        try withStatement(
            """
            SELECT CASE WHEN lower_fact_id = ? THEN upper_fact_id ELSE lower_fact_id END,
                   weight
            FROM cooccurrence_synapses
            WHERE project_id = ? AND (lower_fact_id = ? OR upper_fact_id = ?)
            ORDER BY 1 ASC;
            """
        ) { statement in
            try bind(factID, to: statement, at: 1)
            try bind(projectID, to: statement, at: 2)
            try bind(factID, to: statement, at: 3)
            try bind(factID, to: statement, at: 4)

            var neighbors: [(factID: UUID, weight: Double)] = []
            while try stepToRowOrDone(statement) {
                neighbors.append((
                    factID: try uuid(from: statement, at: 0, name: "cooccurrence neighbor"),
                    weight: Self.clamp(sqlite3_column_double(statement, 1), lower: 0, upper: 1)
                ))
            }
            return neighbors
        }
    }

    private func rankedResults(
        from activations: [UUID: LocalMemoryActivation],
        factsByID: [UUID: LocalMemoryFact],
        limit: Int
    ) -> [LocalMemoryRecallResult] {
        let candidates = activations.values.compactMap { activation -> LocalMemoryRecallResult? in
            guard let fact = factsByID[activation.factID] else { return nil }
            return LocalMemoryRecallResult(
                fact: fact,
                source: fact.source,
                score: Self.clamp(activation.score, lower: 0, upper: 1),
                matchedAnchors: activation.matchedAnchors.sorted(),
                hopCount: activation.hopCount,
                why: activation.why
            )
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
            if lhs.fact.createdAt != rhs.fact.createdAt { return lhs.fact.createdAt > rhs.fact.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.prefix(limit).map { $0 }
    }

    private func ordered(_ activations: [LocalMemoryActivation]) -> [LocalMemoryActivation] {
        activations.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
            return lhs.factID.uuidString < rhs.factID.uuidString
        }
    }

    private func normalized(_ options: LocalMemoryRecallOptions) -> LocalMemoryRecallOptions {
        LocalMemoryRecallOptions(
            maximumHops: min(max(options.maximumHops, 0), Self.maximumSupportedHops),
            decay: Self.clamp(options.decay, lower: 0, upper: 1),
            minimumScore: Self.clamp(options.minimumScore, lower: 0.000_001, upper: 1),
            limit: min(max(options.limit, 1), Self.maximumResultLimit)
        )
    }

    private func anchors(in projectID: String) throws -> [LocalMemoryAnchor] {
        try withStatement(
            """
            SELECT id, project_id, token, created_at
            FROM anchor_neurons
            WHERE project_id = ?
            ORDER BY token ASC, id ASC;
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            var anchors: [LocalMemoryAnchor] = []
            while try stepToRowOrDone(statement) {
                anchors.append(LocalMemoryAnchor(
                    id: try uuid(from: statement, at: 0, name: "anchor_neurons.id"),
                    projectID: try requiredString(from: statement, at: 1, name: "anchor_neurons.project_id"),
                    token: try requiredString(from: statement, at: 2, name: "anchor_neurons.token"),
                    createdAt: try date(from: statement, at: 3, name: "anchor_neurons.created_at")
                ))
            }
            return anchors
        }
    }

    private func synapses(in projectID: String) throws -> [LocalMemorySynapse] {
        let anchorSynapses = try withStatement(
            """
            SELECT fact_id, anchor_id, weight, created_at
            FROM fact_anchor_synapses
            WHERE project_id = ?
            ORDER BY fact_id ASC, anchor_id ASC;
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            var synapses: [LocalMemorySynapse] = []
            while try stepToRowOrDone(statement) {
                let factID = try uuid(from: statement, at: 0, name: "fact_anchor_synapses.fact_id")
                let anchorID = try uuid(from: statement, at: 1, name: "fact_anchor_synapses.anchor_id")
                synapses.append(LocalMemorySynapse(
                    id: "anchor:\(factID.uuidString):\(anchorID.uuidString)",
                    projectID: projectID,
                    sourceID: factID,
                    targetID: anchorID,
                    kind: .factContainsAnchor,
                    weight: Self.clamp(sqlite3_column_double(statement, 2), lower: 0, upper: 1),
                    createdAt: try date(from: statement, at: 3, name: "fact_anchor_synapses.created_at")
                ))
            }
            return synapses
        }
        let cooccurrences = try withStatement(
            """
            SELECT lower_fact_id, upper_fact_id, weight, created_at
            FROM cooccurrence_synapses
            WHERE project_id = ?
            ORDER BY lower_fact_id ASC, upper_fact_id ASC;
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            var synapses: [LocalMemorySynapse] = []
            while try stepToRowOrDone(statement) {
                let lowerID = try uuid(from: statement, at: 0, name: "cooccurrence_synapses.lower_fact_id")
                let upperID = try uuid(from: statement, at: 1, name: "cooccurrence_synapses.upper_fact_id")
                synapses.append(LocalMemorySynapse(
                    id: "cooccur:\(lowerID.uuidString):\(upperID.uuidString)",
                    projectID: projectID,
                    sourceID: lowerID,
                    targetID: upperID,
                    kind: .coOccurs,
                    weight: Self.clamp(sqlite3_column_double(statement, 2), lower: 0, upper: 1),
                    createdAt: try date(from: statement, at: 3, name: "cooccurrence_synapses.created_at")
                ))
            }
            return synapses
        }
        return (anchorSynapses + cooccurrences).sorted { $0.id < $1.id }
    }

    private func deleteOrphanedAnchors(in projectID: String) throws {
        try withStatement(
            """
            DELETE FROM anchor_neurons
            WHERE project_id = ?
              AND NOT EXISTS (
                SELECT 1
                FROM fact_anchor_synapses
                WHERE fact_anchor_synapses.project_id = anchor_neurons.project_id
                  AND fact_anchor_synapses.anchor_id = anchor_neurons.id
              );
            """
        ) { statement in
            try bind(projectID, to: statement, at: 1)
            try stepToDone(statement)
        }
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try executeAndDiscardRows("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try executeAndDiscardRows("COMMIT;")
            return result
        } catch {
            try? executeAndDiscardRows("ROLLBACK;")
            throw error
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let database = try requireDatabase()
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw databaseError(code: prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func executeAndDiscardRows(_ sql: String) throws {
        try withStatement(sql) { statement in
            while try stepToRowOrDone(statement) {}
        }
    }

    private func stepToDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError(code: result) }
    }

    private func stepToRowOrDone(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    private func bind(_ value: UUID, to statement: OpaquePointer, at index: Int32) throws {
        try bind(value.uuidString, to: statement, at: index)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, localMemorySQLiteTransient)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), localMemorySQLiteTransient)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Date, to statement: OpaquePointer, at index: Int32) throws {
        try bind(value.timeIntervalSince1970, to: statement, at: index)
    }

    private func decodeFact(_ statement: OpaquePointer) throws -> LocalMemoryFact {
        let sourceData = try requiredData(from: statement, at: 3, name: "memory_neurons.source_json")
        let provenanceData = try requiredData(from: statement, at: 4, name: "memory_neurons.provenance_json")
        let decoder = JSONDecoder()
        do {
            return LocalMemoryFact(
                id: try uuid(from: statement, at: 0, name: "memory_neurons.id"),
                projectID: try requiredString(from: statement, at: 1, name: "memory_neurons.project_id"),
                content: try requiredString(from: statement, at: 2, name: "memory_neurons.content"),
                source: try decoder.decode(LocalMemorySource.self, from: sourceData),
                provenance: try decoder.decode(LocalMemoryProvenance.self, from: provenanceData),
                createdAt: try date(from: statement, at: 5, name: "memory_neurons.created_at")
            )
        } catch let error as LocalNeuralMemoryError {
            throw error
        } catch {
            throw LocalNeuralMemoryError.corruptData("memory fact JSON cannot be decoded: \(error.localizedDescription)")
        }
    }

    private func uuid(from statement: OpaquePointer, at index: Int32, name: String) throws -> UUID {
        let string = try requiredString(from: statement, at: index, name: name)
        guard let value = UUID(uuidString: string) else {
            throw LocalNeuralMemoryError.corruptData("\(name) is not a UUID")
        }
        return value
    }

    private func requiredString(from statement: OpaquePointer, at index: Int32, name: String) throws -> String {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            throw LocalNeuralMemoryError.corruptData("\(name) is NULL")
        }
        return String(cString: value)
    }

    private func requiredData(from statement: OpaquePointer, at index: Int32, name: String) throws -> Data {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            throw LocalNeuralMemoryError.corruptData("\(name) is NULL")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func date(from statement: OpaquePointer, at index: Int32, name: String) throws -> Date {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw LocalNeuralMemoryError.corruptData("\(name) is NULL")
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else {
            throw LocalNeuralMemoryError.sqlite(code: SQLITE_MISUSE, message: "Database is closed.")
        }
        return database
    }

    private func databaseError(code: Int32? = nil) -> LocalNeuralMemoryError {
        guard let database else {
            return .sqlite(code: code ?? SQLITE_ERROR, message: "Unknown SQLite error.")
        }
        return .sqlite(
            code: code ?? sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private func anchorTokenCounts(for content: String) -> [(token: String, count: Int)] {
        let folded = content
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var counts: [String: Int] = [:]
        for token in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(token)
            guard value.count >= 2, !Self.stopWords.contains(value) else { continue }
            counts[value, default: 0] += 1
        }
        return counts
            .map { (token: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.token < $1.token
            }
            .prefix(configuration.maximumAnchorsPerFact)
            .map { $0 }
    }

    private static func validProjectID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumProjectIDCharacters else {
            throw LocalNeuralMemoryError.invalidProjectID
        }
        return trimmed
    }

    private static func validFact(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumFactCharacters else {
            throw LocalNeuralMemoryError.invalidFact
        }
        return trimmed
    }

    private static func validSource(_ source: LocalMemorySource) throws -> LocalMemorySource {
        let label = source.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= maximumSourceLabelCharacters else {
            throw LocalNeuralMemoryError.invalidSource
        }
        let reference = source.reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference?.count ?? 0 <= maximumSourceLabelCharacters else {
            throw LocalNeuralMemoryError.invalidSource
        }
        return LocalMemorySource(
            kind: source.kind,
            label: label,
            reference: reference?.isEmpty == true ? nil : reference
        )
    }

    private static func validProvenance(
        _ provenance: LocalMemoryProvenance
    ) throws -> LocalMemoryProvenance {
        let capturedBy = provenance.capturedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedBy.isEmpty, capturedBy.count <= maximumProvenanceCharacters else {
            throw LocalNeuralMemoryError.invalidProvenance
        }
        let sourceRecordID = provenance.sourceRecordID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalNote = provenance.approvalNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceRecordID?.count ?? 0 <= maximumProvenanceCharacters,
              approvalNote?.count ?? 0 <= maximumProvenanceCharacters else {
            throw LocalNeuralMemoryError.invalidProvenance
        }
        return LocalMemoryProvenance(
            capturedBy: capturedBy,
            sourceRecordID: sourceRecordID?.isEmpty == true ? nil : sourceRecordID,
            approvalNote: approvalNote?.isEmpty == true ? nil : approvalNote
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func scoreText(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
