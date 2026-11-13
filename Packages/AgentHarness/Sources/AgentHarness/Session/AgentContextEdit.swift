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

    public init(removedMessageIDs: [String]) { self.removedMessageIDs = removedMessageIDs }

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

    /// `messages` with every edit in `edits` applied in order.
    public static func applying(_ edits: [AgentContextEdit], to messages: [AgentMessage]) -> [AgentMessage] {
        edits.reduce(messages) { $1.applied(to: $0) }
    }
}
