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

    public init(id: String, name: String, arguments: JSONValue, rawArguments: String, providerMetadata: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.rawArguments = rawArguments
        self.providerMetadata = providerMetadata
    }
}

public enum AgentMessage: Codable, Sendable, Equatable {
    case user(String)
    case assistant(text: String, toolCalls: [AgentToolCall], providerMetadata: JSONValue? = nil)
    case toolResult(callID: String, toolName: String, content: String, isError: Bool)
}

public struct AgentUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
    }

    func adding(_ other: Self) -> Self {
        Self(inputTokens: inputTokens + other.inputTokens, outputTokens: outputTokens + other.outputTokens)
    }
}

public enum AgentModelStopReason: Codable, Sendable, Equatable {
    case endTurn, toolUse, maxTokens
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
    }
}

public enum AgentModelEvent: Sendable, Equatable {
    case textDelta(String)
}

public struct AgentTurnResponse: Sendable, Equatable {
    public let text: String
    public let toolCalls: [AgentToolCall]
    public let usage: AgentUsage?
    public let stopReason: AgentModelStopReason
    public let providerMetadata: JSONValue?

    public init(text: String, toolCalls: [AgentToolCall] = [], usage: AgentUsage? = nil,
                stopReason: AgentModelStopReason = .endTurn, providerMetadata: JSONValue? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
        self.providerMetadata = providerMetadata
    }
}

public protocol AgentModel: Sendable {
    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse
}

public struct AgentToolOutput: Sendable, Equatable {
    public let content: String
    public let summary: String
    public let isError: Bool
    public let metrics: [AgentDiagnostic.Metric: Int]

    public init(content: String, summary: String, isError: Bool = false, metrics: [AgentDiagnostic.Metric: Int] = [:]) {
        self.content = content
        self.summary = summary
        self.isError = isError
        self.metrics = metrics
    }
}

public struct AgentTool: Sendable {
    public let spec: AgentToolSpec
    public let requiresConfirmation: Bool
    public let execute: @Sendable (JSONValue) async throws -> AgentToolOutput

    public init(spec: AgentToolSpec, requiresConfirmation: Bool = false,
                execute: @escaping @Sendable (JSONValue) async throws -> AgentToolOutput) {
        self.spec = spec
        self.requiresConfirmation = requiresConfirmation
        self.execute = execute
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

    public init(messages: [AgentMessage], finalText: String, stopReason: AgentRunStopReason, totalUsage: AgentUsage) {
        self.messages = messages
        self.finalText = finalText
        self.stopReason = stopReason
        self.totalUsage = totalUsage
    }
}

public enum AgentEvent: Sendable, Equatable {
    case runStarted
    case contextResolved(AgentContextResolution)
    case diagnostic(AgentDiagnostic)
    case turnStarted(index: Int)
    case textDelta(String)
    case toolStarted(callID: String, name: String, arguments: JSONValue)
    case toolFinished(callID: String, name: String, summary: String, isError: Bool)
    case contextCompacted(beforeTokens: Int, afterTokens: Int)
    case usage(AgentUsage)
    case runFinished(AgentRunOutcome)
}
