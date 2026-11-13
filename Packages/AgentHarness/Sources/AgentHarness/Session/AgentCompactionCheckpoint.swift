import Foundation

/// A compaction a run committed (NH06): the summary that replaced every message before
/// `firstKeptMessageID` in its model context. It is saved before the request that uses it, so
/// the next request never runs on context the log does not have, and a later run replaying the
/// same history reuses the summary instead of summarizing again. Only real summaries are
/// checkpoints: an omission note, a failed or cancelled summary, or a compaction that freed
/// nothing never writes one.
public struct AgentCompactionCheckpoint: Codable, Sendable, Equatable {
    public static let entryType = "agent.compaction.v1"

    /// The summary text, without `AgentContextCompactor.summaryPrefix`.
    public let summary: String
    /// The ID of the first message the compaction kept verbatim.
    public let firstKeptMessageID: String
    /// Estimated context tokens before and after the compaction.
    public let tokensBefore: Int
    public let tokensAfter: Int
    /// Whether the cut fell inside a turn, whose earlier part the summary also covers.
    public let splitTurn: Bool

    public init(summary: String, firstKeptMessageID: String, tokensBefore: Int, tokensAfter: Int, splitTurn: Bool) {
        self.summary = summary
        self.firstKeptMessageID = firstKeptMessageID
        self.tokensBefore = max(0, tokensBefore)
        self.tokensAfter = max(0, tokensAfter)
        self.splitTurn = splitTurn
    }

    /// The checkpoint for a compacted context (`AgentContextCompactor.applying`), or nil when the
    /// context does not start with a summary followed by a kept message with an identity.
    init?(compacted: [AgentMessage], tokensBefore: Int, tokensAfter: Int, splitTurn: Bool) {
        guard case .user(let text)? = compacted.first, text.hasPrefix(AgentContextCompactor.summaryPrefix),
              let kept = compacted.dropFirst().first?.canonicalID else { return nil }
        self.init(summary: String(text.dropFirst(AgentContextCompactor.summaryPrefix.count)), firstKeptMessageID: kept,
                  tokensBefore: tokensBefore, tokensAfter: tokensAfter, splitTurn: splitTurn)
    }

    /// `messages` with everything before this checkpoint's first kept message replaced by its
    /// summary, or nil when that message is not among them.
    public func applied(to messages: [AgentMessage]) -> [AgentMessage]? {
        guard let kept = messages.firstIndex(where: { $0.canonicalID == firstKeptMessageID }) else { return nil }
        return [.user(AgentContextCompactor.summaryPrefix + summary)] + messages[kept...]
    }

    /// The newest of `checkpoints` (in commit order) that applies to `messages`, applied; the
    /// messages unchanged when none does.
    public static func compacting(_ messages: [AgentMessage], with checkpoints: [AgentCompactionCheckpoint]) -> [AgentMessage] {
        for checkpoint in checkpoints.reversed() {
            if let compacted = checkpoint.applied(to: messages) { return compacted }
        }
        return messages
    }
}

extension AgentMessage {
    /// The identity of a native message; legacy messages have none.
    public var canonicalID: String? {
        switch self {
        case .content(let message): message.id
        case .tool(let result): result.id
        case .user, .assistant, .toolResult: nil
        }
    }
}

extension AgentRunBranch {
    /// The compactions the run committed, in commit order.
    public var checkpoints: [AgentCompactionCheckpoint] {
        entries.compactMap { entry in
            guard case .custom(AgentCompactionCheckpoint.entryType, let data) = entry.payload,
                  let encoded = try? JSONEncoder().encode(data) else { return nil }
            return try? JSONDecoder().decode(AgentCompactionCheckpoint.self, from: encoded)
        }
    }
}
