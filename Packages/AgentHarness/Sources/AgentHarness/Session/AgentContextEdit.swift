import Foundation

/// A context edit (NH06): it changes what later requests send the model, and nothing else. The
/// raw log keeps every message, the conversation shown to the user keeps every turn, and usage
/// and cost already recorded are untouched; only the projection a later run replays applies it.
///
/// Edits keep calls and results paired: removing an assistant message removes the results of its
/// calls with it, and a named tool result is replaced by a stub result rather than dropped, so
/// no call is ever left without its result.
public struct AgentContextEdit: Codable, Sendable, Equatable {
    public static let entryType = "agent.context-edit.v1"
    /// What stands in for a tool result an edit removed.
    public static let removedResult = "[Removed from the conversation context]"

    /// Messages later context leaves out, by canonical ID.
    public let removedMessageIDs: [String]
    /// Messages an earlier edit left out that later context includes again. Edits are entries,
    /// never rewritten, so undoing one is another edit.
    public let restoredMessageIDs: [String]

    public init(removedMessageIDs: [String], restoredMessageIDs: [String] = []) {
        self.removedMessageIDs = removedMessageIDs
        self.restoredMessageIDs = restoredMessageIDs
    }

    private enum CodingKeys: String, CodingKey { case removedMessageIDs, restoredMessageIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removedMessageIDs = try container.decodeIfPresent([String].self, forKey: .removedMessageIDs) ?? []
        restoredMessageIDs = try container.decodeIfPresent([String].self, forKey: .restoredMessageIDs) ?? []
    }

    /// An edit that restores nothing encodes as it did before restoring existed.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(removedMessageIDs, forKey: .removedMessageIDs)
        if !restoredMessageIDs.isEmpty { try container.encode(restoredMessageIDs, forKey: .restoredMessageIDs) }
    }

    /// This edit as a detached session entry (no parent: it never moves the selected path).
    public func entry(sessionID: String, ordinal: Int, id: String = UUID().uuidString,
                      createdAt: String = AgentSessionEntry.time()) throws -> AgentSessionEntry {
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        return try AgentSessionEntry(sessionID: sessionID, id: id, parentID: nil, ordinal: ordinal, createdAt: createdAt,
                                     payload: .custom(type: Self.entryType, data: data))
    }

    /// The messages left out once every edit in `edits` applied in order.
    public static func excluded(by edits: [AgentContextEdit]) -> Set<String> {
        edits.reduce(into: Set<String>()) { removed, edit in
            removed.formUnion(edit.removedMessageIDs)
            removed.subtract(edit.restoredMessageIDs)
        }
    }

    /// `messages` with this edit applied.
    public func applied(to messages: [AgentMessage]) -> [AgentMessage] {
        let removed = Set(removedMessageIDs)
        var droppedInvocations = Set<String>()
        var droppedCalls = Set<String>()
        for case .content(let message) in messages where removed.contains(message.id) {
            droppedInvocations.formUnion(message.toolCalls.compactMap(\.invocationID))
            droppedCalls.formUnion(message.toolCalls.map(\.id))
        }
        return messages.compactMap { message in
            switch message {
            case .content(let value):
                return removed.contains(value.id) ? nil : message
            case .tool(let result):
                if droppedInvocations.contains(result.invocation.id) || droppedCalls.contains(result.invocation.callID) { return nil }
                guard removed.contains(result.id) else { return message }
                let stub = try? AgentToolResultMessage(id: result.id, timestampMilliseconds: result.timestampMilliseconds,
                    invocation: result.invocation, blocks: [AgentContentBlock(id: "text", content: .text(Self.removedResult))],
                    isError: result.isError)
                return stub.map(AgentMessage.tool) ?? message
            case .user, .assistant, .toolResult:
                return message
            }
        }
    }

    /// Every edit recorded in `entries`, in commit order.
    public static func all(in entries: [AgentSessionEntry]) -> [AgentContextEdit] {
        entries.sorted { $0.ordinal < $1.ordinal }.compactMap { entry in
            guard case .custom(entryType, let data) = entry.payload else { return nil }
            return AgentRunBranch.decode(AgentContextEdit.self, data)
        }
    }

    /// `messages` with every edit in `edits` applied in order: what is left out at the end, so a
    /// message an edit restored is back.
    public static func applying(_ edits: [AgentContextEdit], to messages: [AgentMessage]) -> [AgentMessage] {
        AgentContextEdit(removedMessageIDs: excluded(by: edits).sorted()).applied(to: messages)
    }
}
