import Foundation

/// One run's canonical record in a session log (NH06): the entries an `AgentSession` wrote under
/// the run's ID, from its `agent.run-start.v1` to its `agent.run-end.v1` when the run ended. It is
/// read from the log as values; nothing here writes or resumes a run.
public struct AgentRunBranch: Sendable, Equatable {
    public static let startType = "agent.run-start.v1"
    public static let endType = "agent.run-end.v1"

    public let runID: String
    /// The run's entries in append order, its start entry first.
    public let entries: [AgentSessionEntry]

    /// Every run recorded in `entries` that has a start entry, in the order the runs started.
    public static func all(in entries: [AgentSessionEntry]) -> [AgentRunBranch] {
        var grouped: [String: [AgentSessionEntry]] = [:]
        for entry in entries { if let runID = entry.runID { grouped[runID, default: []].append(entry) } }
        return grouped.compactMap { runID, entries -> AgentRunBranch? in
            let ordered = entries.sorted { $0.ordinal < $1.ordinal }
            guard ordered.first?.kind == startType else { return nil }
            return AgentRunBranch(runID: runID, entries: ordered)
        }.sorted { $0.entries[0].ordinal < $1.entries[0].ordinal }
    }

    /// The host and owner fields of the run's start entry (its authorization, command, …).
    public var startFields: [String: JSONValue] {
        guard case .custom(_, .object(let fields))? = entries.first?.payload else { return [:] }
        return fields
    }

    /// How the run ended (`AgentSessionState.End`'s raw value), or nil while nothing ended it.
    public var end: String? {
        guard case .custom(_, .object(let fields))? = entries.last(where: { $0.kind == Self.endType })?.payload,
              case .string(let end)? = fields["end"] else { return nil }
        return end
    }

    /// The messages the run added to its model's context, in order. Audit records that never
    /// entered that context are left out: a failed, aborted or deferred reply, a reply the output
    /// limit cut off (a retry replaced it, or the run stopped on it), and the results paired with
    /// those replies' calls.
    public var contextMessages: [AgentMessage] {
        var skipped = Set<String>()
        var messages: [AgentMessage] = []
        for entry in entries {
            switch entry.payload {
            case .message(.content(let message)):
                if message.role == .assistant, Self.isAuditOnly(message.stopReason) {
                    skipped.formUnion(message.toolCalls.compactMap(\.invocationID))
                    continue
                }
                messages.append(.content(message))
            case .message(.tool(let result)):
                if !skipped.contains(result.invocation.id) { messages.append(.tool(result)) }
            default: continue
            }
        }
        return messages
    }

    /// The run's answer, when it ended `completed` with its request first and, last in its
    /// context, an assistant reply that calls no tool and says something.
    public var answer: AgentContentMessage? {
        let messages = contextMessages
        guard end == "completed", case .content(let request)? = messages.first, request.role == .user,
              case .content(let reply)? = messages.last, reply.role == .assistant, reply.toolCalls.isEmpty,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return reply
    }

    private static func isAuditOnly(_ reason: AgentModelStopReason?) -> Bool {
        switch reason {
        case .error?, .aborted?, .deferred?, .maxTokens?: return true
        default: return false
        }
    }
}
