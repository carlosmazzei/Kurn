import Foundation

public struct AgentToolSpec: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct AgentToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public internal(set) var arguments: JSONValue
    public let rawArguments: String
    /// Opaque wire metadata needed when replaying a call, such as a Gemini thought signature.
    public let providerMetadata: JSONValue?
    public let namespace: String?
    public let invocationID: String?

    public init(id: String, name: String, arguments: JSONValue, rawArguments: String, providerMetadata: JSONValue? = nil,
                namespace: String? = nil, invocationID: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.rawArguments = rawArguments
        self.providerMetadata = providerMetadata
        self.namespace = namespace
        self.invocationID = invocationID
    }
}

public enum AgentMessage: Codable, Sendable, Equatable {
    /// Native v1 content. Legacy cases retain their original Codable bytes for migration.
    case content(AgentContentMessage)
    case tool(AgentToolResultMessage)
    case user(String)
    case assistant(text: String, toolCalls: [AgentToolCall], providerMetadata: JSONValue? = nil)
    case toolResult(callID: String, toolName: String, content: String, isError: Bool)
}

public struct AgentUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    /// Sum of the reasoning-token counts actually reported (nil if none were reported).
    /// Missing counts are not inferred from output size. Never contains reasoning text.
    /// Reasoning is part of `outputTokens`, never added to it again.
    public let reasoningTokens: Int?
    /// Input tokens the provider read from its prompt cache, and wrote to it (NH07). Both are
    /// part of `inputTokens` — the whole input the request sent, whatever the vendor's own
    /// accounting — never added to it again; nil when the provider reported none.
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = reasoningTokens.map { max(0, $0) }
        self.cacheReadTokens = cacheReadTokens.map { max(0, $0) }
        self.cacheWriteTokens = cacheWriteTokens.map { max(0, $0) }
    }

    func adding(_ other: Self) -> Self {
        Self(inputTokens: inputTokens + other.inputTokens, outputTokens: outputTokens + other.outputTokens,
             reasoningTokens: Self.sum(reasoningTokens, other.reasoningTokens),
             cacheReadTokens: Self.sum(cacheReadTokens, other.cacheReadTokens),
             cacheWriteTokens: Self.sum(cacheWriteTokens, other.cacheWriteTokens))
    }

    /// Reported counts add up; unreported on both sides stays unreported, never zero.
    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        lhs == nil && rhs == nil ? nil : (lhs ?? 0) + (rhs ?? 0)
    }
}

public enum AgentModelStopReason: Codable, Sendable, Equatable {
    case endTurn, toolUse, maxTokens
    case error, aborted, deferred
    case other(String)
}

public struct AgentTurnRequest: Sendable, Equatable {
    public let systemPrompt: String
    public let messages: [AgentMessage]
    public let tools: [AgentToolSpec]
    public let maxOutputTokens: Int
    /// False asks the vendor to answer in text only while tools stay declared (some vendors reject
    /// tool history without declarations): `tool_choice: none` or Gemini's `NONE` calling mode.
    public let allowsToolCalls: Bool
    /// Diagnostic-only loss in a summary request; never serialized as a provider parameter.
    public let contextOmittedCharacters: Int
    public let serializedToolOmittedCharacters: Int
    public let fittedHistoryOmittedCharacters: Int
    public private(set) var identity: AgentRequestIdentity?
    /// A stable key for the conversation, set when the host asks for prompt caching
    /// (`NativeHarness.cachingPrompts(key:)`); the wire formats mark or name the cacheable prefix
    /// with it. Nil leaves the request as it was.
    public private(set) var promptCacheKey: String?

    public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentToolSpec], maxOutputTokens: Int,
                allowsToolCalls: Bool = true, contextOmittedCharacters: Int = 0,
                serializedToolOmittedCharacters: Int = 0, fittedHistoryOmittedCharacters: Int = 0) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.allowsToolCalls = allowsToolCalls
        self.contextOmittedCharacters = contextOmittedCharacters
        self.serializedToolOmittedCharacters = serializedToolOmittedCharacters
        self.fittedHistoryOmittedCharacters = fittedHistoryOmittedCharacters
        self.identity = nil
    }

    public func identified(_ identity: AgentRequestIdentity) -> Self {
        var copy = self
        copy.identity = identity
        return copy
    }

    public func caching(key: String?) -> Self {
        var copy = self
        copy.promptCacheKey = key
        return copy
    }
}

public enum AgentModelEvent: Sendable, Equatable {
    case textDelta(String)
    case content(AgentContentEvent)
    case replayAdjusted(AgentReplayAdjustment)
    /// The wire protocol may require a minimum above the logical headroom floor.
    case outputBudgetAdjusted(requested: Int, sent: Int)
}

public struct AgentTurnResponse: Sendable, Equatable {
    public let text: String
    public let toolCalls: [AgentToolCall]
    public let usage: AgentUsage?
    public let stopReason: AgentModelStopReason
    public let providerMetadata: JSONValue?
    /// Wire adapters discard every tool call from an output-limited response, even complete-looking ones.
    public let discardedToolCalls: Int
    public let message: AgentContentMessage?
    /// Includes interrupted calls retained for audit; these must never be sent to tool execution.
    public let blockedToolCalls: [AgentToolCall]
    public let toolExecutionBlocked: Bool

    public init(text: String, toolCalls: [AgentToolCall] = [], usage: AgentUsage? = nil,
                stopReason: AgentModelStopReason = .endTurn, providerMetadata: JSONValue? = nil, discardedToolCalls: Int = 0,
                message: AgentContentMessage? = nil, blocksToolExecution: Bool = false) {
        let stopReason = message?.stopReason ?? stopReason
        self.text = message?.text ?? text
        let blocked = !stopReason.permitsToolExecution || blocksToolExecution
        toolExecutionBlocked = blocked
        self.toolCalls = blocked ? [] : (message?.toolCalls ?? toolCalls)
        self.usage = message?.usage ?? usage
        self.stopReason = stopReason
        self.providerMetadata = providerMetadata
        blockedToolCalls = blocked ? (message?.toolCalls ?? toolCalls) : []
        self.discardedToolCalls = max(0, max(discardedToolCalls, blockedToolCalls.count))
        self.message = message
    }
}

public protocol AgentModel: Sendable {
    var descriptor: AgentModelDescriptor? { get }
    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse
}

public extension AgentModel { var descriptor: AgentModelDescriptor? { nil } }

public struct AgentToolOutput: Codable, Sendable, Equatable {
    public let content: String
    public let summary: String
    public let isError: Bool
    public let metrics: [AgentDiagnostic.Metric: Int]
    public let details: JSONValue?
    public let structuredContent: JSONValue?

    public init(content: String, summary: String, isError: Bool = false, metrics: [AgentDiagnostic.Metric: Int] = [:],
                details: JSONValue? = nil, structuredContent: JSONValue? = nil) {
        self.content = content
        self.summary = summary
        self.isError = isError
        self.metrics = metrics
        self.details = details
        self.structuredContent = structuredContent
    }
}

public struct AgentTool: Sendable {
    public enum Scheduling: Sendable { case sequential, parallelRead }
    public let spec: AgentToolSpec
    public let requiresConfirmation: Bool
    public let execute: @Sendable (JSONValue) async throws -> AgentToolOutput
    public let executeWithContext: @Sendable (JSONValue, AgentToolExecutionContext) async throws -> AgentToolOutput
    public let scheduling: Scheduling

    public init(spec: AgentToolSpec, requiresConfirmation: Bool = false, scheduling: Scheduling = .sequential,
                execute: @escaping @Sendable (JSONValue) async throws -> AgentToolOutput) {
        self.spec = spec
        self.requiresConfirmation = requiresConfirmation
        self.execute = execute
        executeWithContext = { arguments, _ in try await execute(arguments) }
        self.scheduling = scheduling
    }

    public init(spec: AgentToolSpec, requiresConfirmation: Bool = false, scheduling: Scheduling = .sequential,
                executeWithContext: @escaping @Sendable (JSONValue, AgentToolExecutionContext) async throws -> AgentToolOutput) {
        self.spec = spec; self.requiresConfirmation = requiresConfirmation; self.scheduling = scheduling
        self.executeWithContext = executeWithContext
        execute = { arguments in
            let invocation = try AgentToolInvocation(id: UUID().uuidString, requestID: UUID().uuidString,
                callID: UUID().uuidString, toolName: spec.name)
            return try await executeWithContext(arguments, AgentToolExecutionContext(sessionID: UUID().uuidString, invocation: invocation))
        }
    }
}

public struct AgentLimits: Sendable, Equatable {
    public let maxTurns: Int
    public let maxToolCalls: Int
    public let maxCostUSD: Double?
    /// After a turn or tool-call limit, run one extra tool-less turn so the model answers from what
    /// it already gathered instead of ending on tool results. Never runs past the cost limit.
    public let wrapUpOnLimit: Bool
    public let continuation: AgentContinuationBudget?
    public let workload: AgentWorkload?

    public init(maxTurns: Int = 10, maxToolCalls: Int = 20, maxCostUSD: Double? = nil, wrapUpOnLimit: Bool = false,
                continuation: AgentContinuationBudget? = nil, workload: AgentWorkload? = nil) {
        self.maxTurns = max(0, min(maxTurns, continuation?.maxTurns ?? maxTurns))
        self.maxToolCalls = max(0, min(maxToolCalls, continuation?.maxToolCalls ?? maxToolCalls))
        self.maxCostUSD = maxCostUSD.map { max(0, $0) }
        self.wrapUpOnLimit = wrapUpOnLimit
        self.continuation = continuation
        self.workload = workload
    }
}

public enum AgentRunStopReason: String, Codable, Sendable {
    case completed, turnLimit, toolCallLimit, costLimit, outputLimit
}

public struct AgentRunOutcome: Sendable, Equatable {
    public let messages: [AgentMessage]
    public let finalText: String
    public let stopReason: AgentRunStopReason
    public let totalUsage: AgentUsage
    /// The run's estimated cost in USD from the caller's estimator, including summary requests;
    /// nil when there was no estimator or a reported usage could not be priced. Unknown is never
    /// zero, and an estimate is not a provider billing figure.
    public let estimatedCostUSD: Double?

    public init(messages: [AgentMessage], finalText: String, stopReason: AgentRunStopReason, totalUsage: AgentUsage,
                estimatedCostUSD: Double? = nil) {
        self.messages = messages
        self.finalText = finalText
        self.stopReason = stopReason
        self.totalUsage = totalUsage
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum AgentEvent: Sendable, Equatable {
    case runStarted
    case requestStarted(AgentRequestIdentity)
    case invocationRegistered(AgentToolInvocation)
    case messageAppended(AgentMessage)
    case contextResolved(AgentContextResolution)
    case diagnostic(AgentDiagnostic)
    case turnStarted(index: Int)
    case textDelta(String)
    case modelContent(AgentContentEvent)
    case toolStarted(callID: String, name: String, arguments: JSONValue)
    case toolFinished(callID: String, name: String, summary: String, isError: Bool)
    case toolProgress(invocation: AgentToolInvocation, progress: AgentToolProgress)
    case contextCompacted(beforeTokens: Int, afterTokens: Int)
    case usage(AgentUsage)
    case runFinished(AgentRunOutcome)
}
