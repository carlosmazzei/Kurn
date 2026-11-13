import AgentHarness
import Foundation
import KurnCore

/// The history a chat run replays to the model (NH06 canonical replay). Each earlier answered
/// question goes back as the run that answered it recorded it on its branch (`ChatRunBranch`):
/// its request, every assistant turn with its tool calls, every tool result and its answer — not
/// the plain text the chat shows. A question no recorded run can stand in for (an older
/// conversation, a failed or stopped run, a run that read outside what this run may read) goes
/// back as its plain text, as every question did before.
///
/// A summary a run saved when it compacted (`AgentCompactionCheckpoint`) is reused: the newest one
/// whose first kept message is in the history replaces everything before that message, so a
/// reopened conversation does not summarize the same history again.
///
/// Source boundary: a run's tool results hold what that run was authorized to read. They are
/// replayed only when that authorization was the same source scope as this run's and resolved
/// to no meeting this run cannot read, so narrowing the sources never lets an older answer's
/// reads reach the model. The same rule decides whose summaries are reused.
struct ChatReplayHistory: Sendable {
    /// One shown turn: its ID, role and text.
    struct ShownTurn: Sendable, Equatable {
        let id: UUID
        let role: ChatMessage.Role
        let text: String
    }

    let turns: [ShownTurn]
    /// The runs recorded in the conversation's session, in the order they started.
    let runs: [AgentRunBranch]

    init(turns: [ShownTurn], runs: [AgentRunBranch] = []) {
        self.turns = turns
        self.runs = runs
    }

    /// The conversation's shown turns and the runs recorded in its saved session. Unreadable
    /// history replays the plain turns: the shown conversation is always a valid history.
    @MainActor
    static func load(turns: [ShownTurn], session: ChatSession?, store: SwiftDataAgentSessionStore) -> ChatReplayHistory {
        guard let session, let snapshot = try? store.snapshot(session) else { return ChatReplayHistory(turns: turns) }
        return ChatReplayHistory(turns: turns, runs: AgentRunBranch.all(in: snapshot.entries))
    }

    /// The model history for a run authorized by `authorization`.
    func messages(for authorization: ChatRunAuthorization) -> [AgentMessage] {
        var answers: [UUID: AgentRunBranch] = [:]
        for run in runs where run.answer != nil && Self.allows(run, under: authorization) {
            if let question = ChatRunBranch.questionID(of: run) { answers[question] = run }
        }
        var messages: [AgentMessage] = []
        var index = turns.startIndex
        while index < turns.endIndex {
            let turn = turns[index]
            let next = turns.index(after: index)
            if turn.role == .user, next < turns.endIndex, turns[next].role == .assistant,
               let run = answers[turn.id] {
                messages += run.contextMessages
                index = turns.index(after: next)
                continue
            }
            messages.append(Self.plain(turn))
            index = next
        }
        // Persistent compaction: the newest summary a permitted run saved replaces what it covered.
        let checkpoints = runs.filter { Self.allows($0, under: authorization) }.flatMap(\.checkpoints)
        return AgentCompactionCheckpoint.compacting(messages, with: checkpoints)
    }

    static func plain(_ turn: ShownTurn) -> AgentMessage {
        turn.role == .assistant ? .assistant(text: turn.text, toolCalls: []) : .user(turn.text)
    }

    /// Whether `run`'s reads may reach a run authorized by `current`.
    static func allows(_ run: AgentRunBranch, under current: ChatRunAuthorization) -> Bool {
        guard let recorded = ChatRunBranch.authorization(of: run) else { return false }
        return recorded.scope == current.scope && Set(recorded.meetingIDs).isSubset(of: current.meetingIDs)
    }
}
