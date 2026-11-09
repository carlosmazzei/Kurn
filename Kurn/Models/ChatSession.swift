//
//  ChatSession.swift
//  Kurn
//
//  A saved "chat with your meetings" conversation, the same shape Claude's own
//  mobile app gives its chat history: reopen a past conversation, start a new
//  one, delete one you no longer need. Scoped like the chat feature itself —
//  tied to a `Meeting` for a per-meeting conversation (cascade-deleted with it,
//  like every other transcript-derived artifact), or `meeting == nil` for a
//  library-wide "Ask" conversation. Lives in the one app SwiftData store, so
//  its text is encrypted at rest by `ModelStoreProtection` with everything
//  else — the same rule `SemanticChunk`/`WikiArticle` follow.
//
//  `MeetingChatViewModel` owns reading and writing it: a conversation is
//  created lazily, on its first completed exchange, document mutation or interrupted-run trace, so a chat the
//  user opens and abandons without sending anything never leaves an empty row
//  in the history list.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData

@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    /// Derived once, from the conversation's first question, the moment it's
    /// first saved — see `title(from:)`. Never regenerated afterward, so a
    /// later question in the same conversation doesn't retitle it.
    var title: String
    var createdAt: Date
    /// Bumped on every saved exchange; drives the history list's
    /// most-recently-active-first ordering.
    var updatedAt: Date
    /// Owning meeting, or `nil` for a library-wide "Ask" conversation. The
    /// inverse `Meeting.chatSessions` is `.cascade`, so deleting a meeting
    /// removes its conversations with the rest of its data.
    var meeting: Meeting?
    /// JSON-encoded `[PersistedChatTurn]` behind `turns` below — SwiftData
    /// can't persist a `Codable` array directly, the same `segmentsData`
    /// pattern `Transcript` uses. Authoritative (versioned + checksummed):
    /// this is the user's own questions and the answers grounded in their
    /// meetings, so corruption must read as corruption, never as silently
    /// empty history.
    var turnsData: Data
    var scopeData: Data?
    var artifactsData: Data?
    var canonicalVersion: Int?
    var canonicalLeafID: String?
    var canonicalOrdinal: Int = 0
    var canonicalRevision: Int = 0
    /// Exact pre-conversion bytes are retained independently of the rebuildable UI cache.
    var legacyTurnsData: Data?
    var legacyScopeData: Data?
    var legacyArtifactsData: Data?
    @Relationship(deleteRule: .cascade, inverse: \HarnessSessionEntry.session)
    var harnessEntries: [HarnessSessionEntry] = []
    @Relationship(deleteRule: .cascade, inverse: \HarnessArtifactRevision.session)
    var harnessRevisions: [HarnessArtifactRevision] = []
    @Relationship(deleteRule: .cascade, inverse: \HarnessSessionRecord.session)
    var harnessRecords: [HarnessSessionRecord] = []

    init(meeting: Meeting?, title: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.meeting = meeting
        self.turnsData = JSONStorage.encodeAuthoritative([PersistedChatTurn]()) ?? Data()
    }

    var turns: [PersistedChatTurn] {
        get { JSONStorage.decodeAuthoritative([PersistedChatTurn].self, from: turnsData).decodedValue ?? [] }
        set { turnsData = JSONStorage.encodeAuthoritative(newValue) ?? turnsData }
    }

    /// A short label from a conversation's first question: first line,
    /// trimmed and capped, so a history
    /// row reads as a label rather than the whole question.
    static func title(from question: String) -> String {
        let firstLine = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init) ?? question
        return String(firstLine.prefix(60))
    }
}

/// One persisted turn of a `ChatSession` — a JSON-storable snapshot of
/// `MeetingChatViewModel.Turn`.
struct PersistedChatTurn: Codable {
    var id: UUID
    var role: ChatMessage.Role
    var text: String
    var usage: TokenUsage?
    var costUSD: Double?
    var elapsedSeconds: TimeInterval?
    var steps: [AgentRunStep]? = nil
    var artifacts: [ChatArtifactReference]? = nil
    var artifactOrigins: [UUID: ChatArtifactOrigin]? = nil
}
