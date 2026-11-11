import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Records a chat run's canonical messages and per-request usage in its session log (NH05).
///
/// The run's entries form their own branch, anchored at the conversation's leaf when the run
/// started: each entry's parent is the previous one, and the selected leaf is never moved. So
/// the presentation path — the turns the chat shows and the compatibility writer diffs — is
/// unchanged by a run, and a later presentation branch (an inherited artifact reference, a
/// dropped reply) cannot detach or reorder the run's history. Entries carry the run's
/// `ChatRunRecord` ID as `runID` metadata, the same shape `AgentSession` writes.
///
/// Each append reads the revision and commits in one main-actor step. A failed write throws,
/// which fails the run before any dependent model or tool work (the harness awaits its sinks);
/// the question stays retryable and a retry starts a new branch rather than continuing an
/// incomplete one.
@MainActor
final class ChatRunTranscriptWriter {
    static let usageType = "agent.usage.v1"
    /// The same entry types `AgentSession` writes, with the host's authorization added to the start.
    static let startType = "agent.run-start.v1"
    static let endType = "agent.run-end.v1"

    /// How a run ended, with `AgentSessionState.End`'s raw values.
    enum End: String { case completed, failed, cancelled }

    let runID: String
    private let session: ChatSession
    private let store: SwiftDataAgentSessionStore
    private let anchorID: String?
    private(set) var lastEntryID: String?

    init(runID: String, session: ChatSession, store: SwiftDataAgentSessionStore) {
        self.runID = runID
        self.session = session
        self.store = store
        anchorID = session.canonicalLeafID
    }

    /// The branch's first entry: the sources and model the run was authorized to use.
    func begin(_ authorization: ChatRunAuthorization) throws {
        try append(payload: .custom(type: Self.startType, data: .object([
            "runID": .string(runID), "authorization": try HarnessPresentationCodec.json(authorization)
        ])))
    }

    /// The branch's last entry. `stopReason` is the harness's, when the run produced an outcome.
    func end(_ end: End, stopReason: AgentRunStopReason?) throws {
        try append(payload: .custom(type: Self.endType, data: .object([
            "runID": .string(runID), "end": .string(end.rawValue),
            "stopReason": stopReason.map { .string($0.rawValue) } ?? .null
        ])))
    }

    func append(_ message: AgentMessage) throws {
        try append(payload: .message(message))
    }

    func append(_ usage: AgentUsage) throws {
        try append(payload: .custom(type: Self.usageType, data: .object([
            "inputTokens": .number(Double(usage.inputTokens)),
            "outputTokens": .number(Double(usage.outputTokens)),
            "reasoningTokens": usage.reasoningTokens.map { .number(Double($0)) } ?? .null
        ])))
    }

    /// Whether `entry` belongs to a run branch rather than the presentation path.
    static func runID(of entry: AgentSessionEntry) -> String? {
        guard case .object(let fields)? = entry.metadata, case .string(let id)? = fields["runID"] else { return nil }
        return id
    }

    private func append(payload: AgentSessionEntry.Payload) throws {
        // A run can outlive its session; a deleted row must not be written or resurrected.
        guard !session.isDeleted, session.modelContext != nil else { throw CancellationError() }
        let sessionID = session.id.uuidString
        do {
            // `commitNow` re-validates the whole graph against these values before saving.
            let entry = try AgentSessionEntry(sessionID: sessionID, id: UUID().uuidString,
                parentID: lastEntryID ?? anchorID, ordinal: session.canonicalOrdinal + 1,
                createdAt: AgentSessionEntry.time(), payload: payload,
                metadata: .object(["runID": .string(runID)]))
            try store.commitNow(AgentSessionCommit(sessionID: sessionID, expectedRevision: session.canonicalRevision,
                                                   entries: [entry], leafID: session.canonicalLeafID))
            lastEntryID = entry.id
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: OperationID(String(runID.prefix(8))), operation: "meeting_chat",
                stage: "run_transcript", outcome: .failed, code: "run_transcript_write_failed"
            ))
            throw error
        }
    }
}

/// A run's frozen authorization (NH05): the effective source scope, the meetings it resolved to
/// when the run was prepared, and the `provider:model` that answered. IDs and settings only.
struct ChatRunAuthorization: Codable, Equatable, Sendable {
    let scope: ChatSourceScope
    let meetingIDs: [UUID]
    let model: String

    init(scope: ChatSourceScope, meetingIDs: Set<UUID>, model: String) {
        self.scope = scope
        self.meetingIDs = meetingIDs.sorted { $0.uuidString < $1.uuidString }
        self.model = model
    }
}
