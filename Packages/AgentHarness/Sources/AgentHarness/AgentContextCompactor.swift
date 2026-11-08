import Foundation

/// Context-window policy, following pi-coding-agent's compaction model (its design only, no code):
/// a request is compacted once its context exceeds the model's real window minus a reserve kept
/// free for the reply, and a compaction keeps roughly the newest `keepRecentTokens` verbatim.
public struct AgentContextPolicy: Sendable, Equatable {
    public static let defaultReserveTokens = 16_384
    public static let defaultKeepRecentTokens = 20_000

    /// Total tokens the model accepts per request.
    public let contextWindow: Int
    /// Tokens left free for the reply and estimate error; also sizes the summary requests.
    public let reserveTokens: Int
    /// Approximate size of the newest messages a compaction keeps verbatim.
    public let keepRecentTokens: Int
    public let summaryPrompts: AgentCompactionPrompts

    public init(contextWindow: Int, reserveTokens: Int = defaultReserveTokens,
                keepRecentTokens: Int = defaultKeepRecentTokens, summaryPrompts: AgentCompactionPrompts = .standard) {
        self.contextWindow = max(1, contextWindow)
        self.reserveTokens = max(0, reserveTokens)
        self.keepRecentTokens = max(1, keepRecentTokens)
        self.summaryPrompts = summaryPrompts
    }

    /// Context size above which a request is compacted: the window minus the reserve, but never
    /// below half the window, so a model whose window is smaller than the reserve still has room.
    public var compactionThreshold: Int { max(contextWindow / 2, contextWindow - reserveTokens) }

    /// The verbatim tail a compaction keeps, capped at half the threshold so compacting a small
    /// window always frees room.
    public var effectiveKeepRecentTokens: Int { max(1, min(keepRecentTokens, compactionThreshold / 2)) }

    /// Output allowance of the history summary (80% of the reserve, as in pi) and of a split turn's
    /// prefix summary (50%), each capped at a quarter/eighth of the window so the summary request
    /// itself fits a small-window model (an 8k model would otherwise be asked for 13k of output).
    public var historySummaryMaxOutputTokens: Int { max(64, min(reserveTokens * 4 / 5, contextWindow / 4)) }
    public var turnPrefixSummaryMaxOutputTokens: Int { max(64, min(reserveTokens / 2, contextWindow / 8)) }

    func needsCompaction(_ tokens: Int) -> Bool { tokens > compactionThreshold }
}

/// What one compaction replaces and keeps. The newest messages from the cut point on are kept
/// verbatim; older ones are summarized. A cut inside the current turn (one user message plus
/// every assistant/tool exchange it started) is a split turn: the turn's earlier part gets its
/// own summary so the kept suffix still has its request and context.
public struct AgentCompactionPlan: Sendable, Equatable {
    public let previousSummary: String?
    public let messagesToSummarize: [AgentMessage]
    public let turnPrefix: [AgentMessage]
    public let kept: [AgentMessage]

    public var isSplitTurn: Bool { !turnPrefix.isEmpty }
}

/// Pure context transformations; the harness supplies the summary calls.
public struct AgentContextCompactor: Sendable {
    public let policy: AgentContextPolicy
    private let tokenEstimator: @Sendable (String) -> Int

    public init(policy: AgentContextPolicy,
                tokenEstimator: @escaping @Sendable (String) -> Int = { TokenEstimate.tokens(in: $0) }) {
        self.policy = policy
        self.tokenEstimator = tokenEstimator
    }

    /// Fixed per-message and per-tool-call framing (role markers, call IDs) that vendors add.
    public static let messageOverheadTokens = 4
    /// Marks the user message that carries a compaction summary at the head of the context.
    public static let summaryPrefix = "[Summary of earlier conversation]\n"
    /// Last resort when even the summary request exceeds the provider's window.
    public static let omittedPrefixNote = "[Earlier conversation omitted to fit the model's context window]"
    /// Tool results are clipped to this many characters in a summary request: they are the
    /// largest part of the context, and an unclipped summary request could overflow the window
    /// it is meant to relieve.
    public static let serializedToolResultLimit = 2_000

    // MARK: - Estimates

    /// Estimates the request as the provider receives it: message text, tool-call arguments and
    /// replay metadata are counted once, rather than re-encoding already-JSON tool results as JSON
    /// strings, whose escaping inflated the estimate and compacted context that still fit.
    public func estimateTokens(systemPrompt: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> Int {
        let toolText = tools.isEmpty ? "" : encoded(tools)
        return estimate(systemPrompt) + estimateTokens(of: messages) + estimate(toolText)
    }

    public func estimateTokens<Messages: Sequence>(of messages: Messages) -> Int where Messages.Element == AgentMessage {
        messages.reduce(0) { $0 + estimateTokens(of: $1) }
    }

    public func estimateTokens(of message: AgentMessage) -> Int {
        let overhead = Self.messageOverheadTokens
        switch message {
        case .user(let text):
            return overhead + estimate(text)
        case .assistant(let text, let calls, let metadata):
            let callTokens = calls.reduce(0) { total, call in
                total + overhead + estimate(call.id) + estimate(call.name) + estimate(call.rawArguments)
                    + estimate(call.providerMetadata.map { encoded($0) } ?? "")
            }
            return overhead + estimate(text) + callTokens + estimate(metadata.map { encoded($0) } ?? "")
        case .toolResult(let callID, _, let content, _):
            return overhead + estimate(callID) + estimate(content)
        }
    }

    // MARK: - Planning

    /// Plans a compaction of `messages`, or nil when nothing older than the kept tail exists.
    /// Walks back from the newest message until `effectiveKeepRecentTokens` is reached and cuts at
    /// the nearest user or assistant message at or after that point, never at a tool result, so a
    /// call always stays with its results.
    public func plan(for messages: [AgentMessage]) -> AgentCompactionPlan? {
        let (previousSummary, start) = Self.previousSummary(in: messages)
        let cutPoints = (start..<messages.count).filter { !Self.isToolResult(messages[$0]) }
        guard let firstCut = cutPoints.first else { return nil }
        var cut = firstCut
        var accumulated = 0
        for index in stride(from: messages.count - 1, through: start, by: -1) {
            accumulated += estimateTokens(of: messages[index])
            if accumulated >= policy.effectiveKeepRecentTokens {
                cut = cutPoints.first { $0 >= index } ?? cutPoints.last { $0 <= index } ?? firstCut
                break
            }
        }
        let turnStart: Int? = Self.isUser(messages[cut]) ? nil
            : (start...cut).reversed().first { Self.isUser(messages[$0]) }
        let historyEnd = turnStart ?? cut
        let toSummarize = Array(messages[start..<historyEnd])
        let prefix = turnStart.map { Array(messages[$0..<cut]) } ?? []
        guard !toSummarize.isEmpty || !prefix.isEmpty else { return nil }
        return AgentCompactionPlan(previousSummary: previousSummary, messagesToSummarize: toSummarize,
                                   turnPrefix: prefix, kept: Array(messages[cut...]))
    }

    /// The summary request for the history before the cut (or before the split turn), updating
    /// the previous compaction's summary when there is one; nil when there is no such history.
    public func historySummaryRequest(for plan: AgentCompactionPlan) -> AgentTurnRequest? {
        guard !plan.messagesToSummarize.isEmpty else { return nil }
        let instructions = plan.previousSummary.map {
            "<previous-summary>\n\($0)\n</previous-summary>\n\n" + policy.summaryPrompts.updateSummary
        } ?? policy.summaryPrompts.historySummary
        return summaryRequest(conversation: plan.messagesToSummarize, instructions: instructions,
                              maxOutputTokens: policy.historySummaryMaxOutputTokens)
    }

    /// The summary request for a split turn's earlier part; nil when the cut is at a turn start.
    public func turnPrefixSummaryRequest(for plan: AgentCompactionPlan) -> AgentTurnRequest? {
        guard plan.isSplitTurn else { return nil }
        return summaryRequest(conversation: plan.turnPrefix, instructions: policy.summaryPrompts.turnPrefix,
                              maxOutputTokens: policy.turnPrefixSummaryMaxOutputTokens)
    }

    /// Notes that the oldest part of a summary request's conversation was dropped to fit the window.
    public static let truncatedConversationNote = "[Earlier part of the conversation omitted to fit the context window]"
    /// Margin for vendor framing around the summary request.
    static let summaryRequestMarginTokens = 64

    /// A tool-less summary request whose serialized conversation is trimmed from its oldest end so
    /// that input and output together fit the context window.
    private func summaryRequest(conversation messages: [AgentMessage], instructions: String,
                                maxOutputTokens: Int) -> AgentTurnRequest {
        let tail = "\n</conversation>\n\n" + instructions
        let budget = policy.contextWindow - maxOutputTokens - Self.summaryRequestMarginTokens
            - estimate(policy.summaryPrompts.system) - estimate("<conversation>\n" + tail)
            - Self.messageOverheadTokens
        let serialized = Self.serialize(messages)
        let conversation = fitted(serialized, toTokens: budget)
        let clipped = messages.reduce(0) { count, message in
            guard case .toolResult(_, _, let content, _) = message else { return count }
            return count + max(0, content.count - Self.serializedToolResultLimit)
        }
        let omitted = conversation == serialized ? 0
            : max(0, serialized.count - conversation.count + Self.truncatedConversationNote.count + 1)
        return AgentTurnRequest(systemPrompt: policy.summaryPrompts.system,
                                messages: [.user("<conversation>\n" + conversation + tail)],
                                tools: [], maxOutputTokens: maxOutputTokens, contextOmittedCharacters: clipped + omitted)
    }

    /// Keeps the newest part of `text` that fits `budget` estimated tokens, marked as truncated.
    private func fitted(_ text: String, toTokens budget: Int) -> String {
        let total = estimate(text)
        guard total > budget else { return text }
        let note = Self.truncatedConversationNote + "\n"
        // Start from the proportional share, then shrink by 10% until the estimate fits.
        var keep = Int(Double(text.count) * Double(max(0, budget)) / Double(max(1, total)))
        while keep > 0 {
            let candidate = note + String(text.suffix(keep))
            if estimate(candidate) <= budget { return candidate }
            keep = min(keep - 1, keep * 9 / 10)
        }
        return note
    }

    /// The compacted context: one summary message followed by the kept messages.
    public func applying(_ plan: AgentCompactionPlan, historySummary: String?, turnPrefixSummary: String?) -> [AgentMessage] {
        var summary = historySummary ?? plan.previousSummary ?? "No prior history."
        if plan.isSplitTurn, let turnPrefixSummary {
            summary += "\n\n---\n\n**Turn context (split turn):**\n\n" + turnPrefixSummary
        }
        return [.user(Self.summaryPrefix + summary)] + plan.kept
    }

    /// Keeps the previous summary (if any) and the kept messages, dropping what could not be
    /// summarized; used only when the summary request itself exceeded the provider's window.
    public func omitting(_ plan: AgentCompactionPlan) -> [AgentMessage] {
        let note = [plan.previousSummary, Self.omittedPrefixNote].compactMap { $0 }.joined(separator: "\n\n")
        return [.user(Self.summaryPrefix + note)] + plan.kept
    }

    // MARK: - Serialization

    /// The conversation as labelled text, so the summarizing model reads it as data instead of
    /// continuing it, with tool results clipped to `serializedToolResultLimit` characters.
    public static func serialize(_ messages: [AgentMessage]) -> String {
        var parts: [String] = []
        for message in messages {
            switch message {
            case .user(let text):
                if !text.isEmpty { parts.append("[User]: \(text)") }
            case .assistant(let text, let calls, _):
                if !text.isEmpty { parts.append("[Assistant]: \(text)") }
                if !calls.isEmpty {
                    parts.append("[Assistant tool calls]: " + calls.map { "\($0.name)(\($0.rawArguments))" }
                        .joined(separator: "; "))
                }
            case .toolResult(_, let name, let content, let isError):
                parts.append("[\(isError ? "Tool error" : "Tool result") \(name)]: \(clipped(content))")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func clipped(_ text: String) -> String {
        guard text.count > serializedToolResultLimit else { return text }
        return String(text.prefix(serializedToolResultLimit))
            + "\n[... \(text.count - serializedToolResultLimit) more characters truncated]"
    }

    private static func previousSummary(in messages: [AgentMessage]) -> (String?, Int) {
        guard case .user(let text)? = messages.first, text.hasPrefix(summaryPrefix) else { return (nil, 0) }
        return (String(text.dropFirst(summaryPrefix.count)), 1)
    }

    private static func isUser(_ message: AgentMessage) -> Bool {
        if case .user = message { return true }
        return false
    }

    private static func isToolResult(_ message: AgentMessage) -> Bool {
        if case .toolResult = message { return true }
        return false
    }

    private func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(0, tokenEstimator(text))
    }

    private func encoded<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
