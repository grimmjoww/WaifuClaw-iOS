import Foundation

/// The role assigned to a message created by the on-device agent.
public enum LocalRole: String, Codable, CaseIterable, Sendable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// The persisted lifecycle phase of an on-device agent run.
public enum LocalRunPhase: String, Codable, CaseIterable, Sendable, Hashable {
    case queued
    case running
    case finished
    case failed
    case cancelled
}

/// A locally persisted agent conversation.
public struct LocalConversation: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A message belonging to a locally persisted conversation.
public struct LocalMessage: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let conversationID: UUID
    public let role: LocalRole
    public let content: String
    public let createdAt: Date

    public init(
        id: UUID,
        conversationID: UUID,
        role: LocalRole,
        content: String,
        createdAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// A locally persisted invocation of the native coding agent.
public struct LocalRunRecord: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let conversationID: UUID
    public let phase: LocalRunPhase
    public let createdAt: Date
    public let updatedAt: Date
    public let errorMessage: String?

    public init(
        id: UUID,
        conversationID: UUID,
        phase: LocalRunPhase,
        createdAt: Date,
        updatedAt: Date,
        errorMessage: String?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }
}

/// An append-only event emitted while a native agent run progresses.
public struct LocalRunEvent: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let runID: UUID
    public let kind: String
    public let summary: String
    public let createdAt: Date

    public init(id: UUID, runID: UUID, kind: String, summary: String, createdAt: Date) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.summary = summary
        self.createdAt = createdAt
    }
}
