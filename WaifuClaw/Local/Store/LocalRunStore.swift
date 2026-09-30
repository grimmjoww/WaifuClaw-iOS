import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Errors emitted while opening, migrating, or querying the local run database.
public enum LocalRunStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidDatabaseURL(String)
    case applicationSupportUnavailable
    case incompatibleSchemaVersion(found: Int, supported: Int)
    case sqlite(code: Int32, message: String)
    case recordNotFound(entity: String, id: UUID)
    case corruptData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL(let value):
            return "The database URL is not a file URL: \(value)"
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .incompatibleSchemaVersion(let found, let supported):
            return "Database schema version \(found) is newer than supported version \(supported)."
        case .sqlite(let code, let message):
            return "SQLite error \(code): \(message)"
        case .recordNotFound(let entity, let id):
            return "\(entity) \(id.uuidString) was not found."
        case .corruptData(let description):
            return "The local database contains invalid data: \(description)"
        }
    }
}

/// Actor-isolated SQLite persistence for the on-device coding agent.
///
/// The store keeps user-authored data only. Model credentials and other secrets
/// belong in the Keychain and must never be written to this database.
public actor LocalRunStore {
    private static let schemaVersion = 1

    private var database: OpaquePointer?

    /// Opens a store at `databaseURL`, or creates the app's standard Application
    /// Support database when no URL is supplied.
    public init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        guard resolvedURL.isFileURL else {
            throw LocalRunStoreError.invalidDatabaseURL(resolvedURL.absoluteString)
        }

        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            resolvedURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard openResult == SQLITE_OK, let openedDatabase else {
            let message: String
            if let openedDatabase {
                message = String(cString: sqlite3_errmsg(openedDatabase))
            } else {
                message = "Unable to open database."
            }
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw LocalRunStoreError.sqlite(code: openResult, message: message)
        }

        database = openedDatabase
        do {
            try configureConnection()
            try migrateIfNeeded()
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

    /// Creates a conversation with no messages or runs.
    public func createConversation(title: String) throws -> LocalConversation {
        let now = Date()
        let conversation = LocalConversation(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now
        )

        try withStatement(
            """
            INSERT INTO conversations (id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?);
            """
        ) { statement in
            try bind(conversation.id, to: statement, at: 1)
            try bind(conversation.title, to: statement, at: 2)
            try bind(conversation.createdAt, to: statement, at: 3)
            try bind(conversation.updatedAt, to: statement, at: 4)
            try stepToDone(statement)
        }

        return conversation
    }

    /// Lists conversations newest activity first, with deterministic tie-breaking.
    public func listConversations() throws -> [LocalConversation] {
        try withStatement(
            """
            SELECT id, title, created_at, updated_at
            FROM conversations
            ORDER BY updated_at DESC, created_at DESC, id ASC;
            """
        ) { statement in
            var conversations: [LocalConversation] = []
            while try stepToRowOrDone(statement) {
                conversations.append(try decodeConversation(statement))
            }
            return conversations
        }
    }

    /// Deletes all phone-local conversations and their messages, runs and run
    /// events through enforced SQLite foreign-key cascades. Provider keys and
    /// approved project memories have separate explicit deletion controls.
    @discardableResult
    public func deleteAllConversations() throws -> Int {
        let count = try withStatement("SELECT COUNT(*) FROM conversations;") { statement in
            guard try stepToRowOrDone(statement) else {
                throw LocalRunStoreError.corruptData("Conversation count was unavailable")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
        try withStatement("DELETE FROM conversations;") { statement in
            try stepToDone(statement)
        }
        return count
    }

    /// Appends a message and marks its parent conversation as recently updated.
    public func appendMessage(
        conversationID: UUID,
        role: LocalRole,
        content: String
    ) throws -> LocalMessage {
        let now = Date()
        let message = LocalMessage(
            id: UUID(),
            conversationID: conversationID,
            role: role,
            content: content,
            createdAt: now
        )

        return try inTransaction {
            try withStatement(
                """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(message.id, to: statement, at: 1)
                try bind(message.conversationID, to: statement, at: 2)
                try bind(message.role.rawValue, to: statement, at: 3)
                try bind(message.content, to: statement, at: 4)
                try bind(message.createdAt, to: statement, at: 5)
                try stepToDone(statement)
            }
            try touchConversation(id: conversationID, at: now)
            return message
        }
    }

    /// Returns all messages in chronological, deterministic order.
    public func messages(in conversationID: UUID) throws -> [LocalMessage] {
        try withStatement(
            """
            SELECT id, conversation_id, role, content, created_at
            FROM messages
            WHERE conversation_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        ) { statement in
            try bind(conversationID, to: statement, at: 1)
            var messages: [LocalMessage] = []
            while try stepToRowOrDone(statement) {
                messages.append(try decodeMessage(statement))
            }
            return messages
        }
    }

    /// Creates a queued native-agent run and updates the parent conversation timestamp.
    public func createRun(conversationID: UUID) throws -> LocalRunRecord {
        let now = Date()
        let run = LocalRunRecord(
            id: UUID(),
            conversationID: conversationID,
            phase: .queued,
            createdAt: now,
            updatedAt: now,
            errorMessage: nil
        )

        return try inTransaction {
            try withStatement(
                """
                INSERT INTO runs (id, conversation_id, phase, created_at, updated_at, error_message)
                VALUES (?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(run.id, to: statement, at: 1)
                try bind(run.conversationID, to: statement, at: 2)
                try bind(run.phase.rawValue, to: statement, at: 3)
                try bind(run.createdAt, to: statement, at: 4)
                try bind(run.updatedAt, to: statement, at: 5)
                try bind(run.errorMessage, to: statement, at: 6)
                try stepToDone(statement)
            }
            try touchConversation(id: conversationID, at: now)
            return run
        }
    }

    /// Changes a run phase and stores an optional human-readable failure detail.
    public func setRunPhase(
        _ id: UUID,
        phase: LocalRunPhase,
        error: String?
    ) throws {
        try withStatement(
            """
            UPDATE runs
            SET phase = ?, updated_at = ?, error_message = ?
            WHERE id = ?;
            """
        ) { statement in
            try bind(phase.rawValue, to: statement, at: 1)
            try bind(Date(), to: statement, at: 2)
            try bind(error, to: statement, at: 3)
            try bind(id, to: statement, at: 4)
            try stepToDone(statement)
        }

        guard sqlite3_changes(try requireDatabase()) == 1 else {
            throw LocalRunStoreError.recordNotFound(entity: "Run", id: id)
        }
    }

    /// Returns runs for one conversation in chronological, deterministic order.
    public func runs(in conversationID: UUID) throws -> [LocalRunRecord] {
        try withStatement(
            """
            SELECT id, conversation_id, phase, created_at, updated_at, error_message
            FROM runs
            WHERE conversation_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        ) { statement in
            try bind(conversationID, to: statement, at: 1)
            var runs: [LocalRunRecord] = []
            while try stepToRowOrDone(statement) {
                runs.append(try decodeRun(statement))
            }
            return runs
        }
    }

    /// Appends an event and atomically updates the parent run's activity timestamp.
    public func appendEvent(runID: UUID, kind: String, summary: String) throws -> LocalRunEvent {
        let now = Date()
        let event = LocalRunEvent(
            id: UUID(),
            runID: runID,
            kind: kind,
            summary: summary,
            createdAt: now
        )

        return try inTransaction {
            try withStatement(
                """
                INSERT INTO run_events (id, run_id, kind, summary, created_at)
                VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(event.id, to: statement, at: 1)
                try bind(event.runID, to: statement, at: 2)
                try bind(event.kind, to: statement, at: 3)
                try bind(event.summary, to: statement, at: 4)
                try bind(event.createdAt, to: statement, at: 5)
                try stepToDone(statement)
            }
            try touchRun(id: runID, at: now)
            return event
        }
    }

    /// Returns events for one run in chronological, deterministic order.
    public func events(in runID: UUID) throws -> [LocalRunEvent] {
        try withStatement(
            """
            SELECT id, run_id, kind, summary, created_at
            FROM run_events
            WHERE run_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        ) { statement in
            try bind(runID, to: statement, at: 1)
            var events: [LocalRunEvent] = []
            while try stepToRowOrDone(statement) {
                events.append(try decodeEvent(statement))
            }
            return events
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalRunStoreError.applicationSupportUnavailable
        }

        let directory = applicationSupport.appendingPathComponent("WaifuClaw", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("LocalRunStore.sqlite", isDirectory: false)
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
            throw LocalRunStoreError.corruptData("PRAGMA user_version is negative")
        }
        guard currentVersion <= Self.schemaVersion else {
            throw LocalRunStoreError.incompatibleSchemaVersion(
                found: currentVersion,
                supported: Self.schemaVersion
            )
        }
        guard currentVersion == 0 else { return }

        try inTransaction {
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
                    content TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    phase TEXT NOT NULL CHECK (phase IN ('queued', 'running', 'finished', 'failed', 'cancelled')),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    error_message TEXT
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE TABLE IF NOT EXISTS run_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS messages_conversation_created_idx
                ON messages(conversation_id, created_at, id);
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS runs_conversation_created_idx
                ON runs(conversation_id, created_at, id);
                """
            )
            try executeAndDiscardRows(
                """
                CREATE INDEX IF NOT EXISTS run_events_run_created_idx
                ON run_events(run_id, created_at, id);
                """
            )
            try executeAndDiscardRows("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private func userVersion() throws -> Int {
        try withStatement("PRAGMA user_version;") { statement in
            guard try stepToRowOrDone(statement) else {
                throw LocalRunStoreError.corruptData("PRAGMA user_version returned no row")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func inTransaction<T>(_ work: () throws -> T) throws -> T {
        try executeAndDiscardRows("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try work()
            try executeAndDiscardRows("COMMIT;")
            return result
        } catch {
            try? executeAndDiscardRows("ROLLBACK;")
            throw error
        }
    }

    private func touchConversation(id: UUID, at date: Date) throws {
        try withStatement(
            "UPDATE conversations SET updated_at = ? WHERE id = ?;"
        ) { statement in
            try bind(date, to: statement, at: 1)
            try bind(id, to: statement, at: 2)
            try stepToDone(statement)
        }
        guard sqlite3_changes(try requireDatabase()) == 1 else {
            throw LocalRunStoreError.recordNotFound(entity: "Conversation", id: id)
        }
    }

    private func touchRun(id: UUID, at date: Date) throws {
        try withStatement("UPDATE runs SET updated_at = ? WHERE id = ?;") { statement in
            try bind(date, to: statement, at: 1)
            try bind(id, to: statement, at: 2)
            try stepToDone(statement)
        }
        guard sqlite3_changes(try requireDatabase()) == 1 else {
            throw LocalRunStoreError.recordNotFound(entity: "Run", id: id)
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
        guard result == SQLITE_DONE else {
            throw databaseError(code: result)
        }
    }

    private func stepToRowOrDone(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw databaseError(code: result)
        }
    }

    private func bind(_ value: UUID, to statement: OpaquePointer, at index: Int32) throws {
        try bind(value.uuidString, to: statement, at: index)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw databaseError(code: result)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw databaseError(code: result)
            }
            return
        }
        try bind(value, to: statement, at: index)
    }

    private func bind(_ value: Date, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        guard result == SQLITE_OK else {
            throw databaseError(code: result)
        }
    }

    private func decodeConversation(_ statement: OpaquePointer) throws -> LocalConversation {
        LocalConversation(
            id: try uuid(from: statement, at: 0, name: "conversation.id"),
            title: try requiredString(from: statement, at: 1, name: "conversation.title"),
            createdAt: try date(from: statement, at: 2, name: "conversation.created_at"),
            updatedAt: try date(from: statement, at: 3, name: "conversation.updated_at")
        )
    }

    private func decodeMessage(_ statement: OpaquePointer) throws -> LocalMessage {
        let roleValue = try requiredString(from: statement, at: 2, name: "message.role")
        guard let role = LocalRole(rawValue: roleValue) else {
            throw LocalRunStoreError.corruptData("message.role has unsupported value \(roleValue)")
        }
        return LocalMessage(
            id: try uuid(from: statement, at: 0, name: "message.id"),
            conversationID: try uuid(from: statement, at: 1, name: "message.conversation_id"),
            role: role,
            content: try requiredString(from: statement, at: 3, name: "message.content"),
            createdAt: try date(from: statement, at: 4, name: "message.created_at")
        )
    }

    private func decodeRun(_ statement: OpaquePointer) throws -> LocalRunRecord {
        let phaseValue = try requiredString(from: statement, at: 2, name: "run.phase")
        guard let phase = LocalRunPhase(rawValue: phaseValue) else {
            throw LocalRunStoreError.corruptData("run.phase has unsupported value \(phaseValue)")
        }
        return LocalRunRecord(
            id: try uuid(from: statement, at: 0, name: "run.id"),
            conversationID: try uuid(from: statement, at: 1, name: "run.conversation_id"),
            phase: phase,
            createdAt: try date(from: statement, at: 3, name: "run.created_at"),
            updatedAt: try date(from: statement, at: 4, name: "run.updated_at"),
            errorMessage: optionalString(from: statement, at: 5)
        )
    }

    private func decodeEvent(_ statement: OpaquePointer) throws -> LocalRunEvent {
        LocalRunEvent(
            id: try uuid(from: statement, at: 0, name: "event.id"),
            runID: try uuid(from: statement, at: 1, name: "event.run_id"),
            kind: try requiredString(from: statement, at: 2, name: "event.kind"),
            summary: try requiredString(from: statement, at: 3, name: "event.summary"),
            createdAt: try date(from: statement, at: 4, name: "event.created_at")
        )
    }

    private func uuid(
        from statement: OpaquePointer,
        at index: Int32,
        name: String
    ) throws -> UUID {
        let string = try requiredString(from: statement, at: index, name: name)
        guard let value = UUID(uuidString: string) else {
            throw LocalRunStoreError.corruptData("\(name) is not a UUID")
        }
        return value
    }

    private func requiredString(
        from statement: OpaquePointer,
        at index: Int32,
        name: String
    ) throws -> String {
        guard let value = optionalString(from: statement, at: index) else {
            throw LocalRunStoreError.corruptData("\(name) is NULL")
        }
        return value
    }

    private func optionalString(from statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func date(from statement: OpaquePointer, at index: Int32, name: String) throws -> Date {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw LocalRunStoreError.corruptData("\(name) is NULL")
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else {
            throw LocalRunStoreError.sqlite(code: SQLITE_MISUSE, message: "Database is closed.")
        }
        return database
    }

    private func databaseError(code: Int32? = nil) -> LocalRunStoreError {
        guard let database else {
            return .sqlite(
                code: code ?? SQLITE_ERROR,
                message: "Unknown SQLite error."
            )
        }
        let resolvedCode = code ?? sqlite3_errcode(database)
        let message = String(cString: sqlite3_errmsg(database))
        return .sqlite(code: resolvedCode, message: message)
    }
}
