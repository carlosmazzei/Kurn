import AgentHarness
import Foundation
import KurnCore

/// A chat run's canonical history in its saved session (NH05), written by an `AgentSession`
/// owner in `.branch` mode: the question, each assistant turn and tool result, and each
/// request's usage, between `agent.run-start.v1` (with the run's `ChatRunAuthorization`) and
/// `agent.run-end.v1`. The branch hangs from the accepted question and never moves the selected
/// leaf, so the presentation path the chat shows and the compatibility writer diffs is unchanged
/// by a run. Its entries carry the run's `ChatRunRecord` ID as `runID` metadata.
enum ChatRunBranch {
    static let startType = "agent.run-start.v1"
    static let usageType = "agent.usage.v1"
    static let endType = "agent.run-end.v1"

    /// The owner of one run's branch in `session`.
    static func owner(session: ChatSession, store: SwiftDataAgentSessionStore) throws -> AgentSession {
        try AgentSession(sessionID: session.id.uuidString, store: store, appendMode: .branch)
    }

    /// The run-start fields the host adds: what the run was authorized to read and which model answers.
    static func startFields(_ authorization: ChatRunAuthorization) throws -> [String: JSONValue] {
        ["authorization": try HarnessPresentationCodec.json(authorization)]
    }

    /// Whether `entry` belongs to a run branch rather than the presentation path.
    static func runID(of entry: AgentSessionEntry) -> String? {
        guard case .object(let fields)? = entry.metadata, case .string(let id)? = fields["runID"] else { return nil }
        return id
    }

    /// Whether `error` is a run history write that failed; the chat says so rather than showing
    /// the store's own error text.
    static func isWriteFailure(_ error: Error) -> Bool {
        (error as? AgentSessionOwnerError) == .persistenceFailed
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
