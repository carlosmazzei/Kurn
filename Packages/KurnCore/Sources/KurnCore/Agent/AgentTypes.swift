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
    public let arguments: JSONValue
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
    case assistant(text: String, toolCalls: [AgentToolCall])
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

    public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentToolSpec], maxOutputTokens: Int) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
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

    public init(text: String, toolCalls: [AgentToolCall] = [], usage: AgentUsage? = nil,
                stopReason: AgentModelStopReason = .endTurn) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
    }
}

public protocol AgentModel: Sendable {
    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse
}

public struct AgentToolOutput: Sendable, Equatable {
    public let content: String
    public let summary: String

    public init(content: String, summary: String) {
        self.content = content
        self.summary = summary
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

    public init(maxTurns: Int = 10, maxToolCalls: Int = 20, maxCostUSD: Double? = nil) {
        self.maxTurns = max(0, maxTurns)
        self.maxToolCalls = max(0, maxToolCalls)
        self.maxCostUSD = maxCostUSD.map { max(0, $0) }
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
    case turnStarted(index: Int)
    case textDelta(String)
    case toolStarted(callID: String, name: String, arguments: JSONValue)
    case toolFinished(callID: String, name: String, summary: String, isError: Bool)
    case contextCompacted(beforeTokens: Int, afterTokens: Int)
    case usage(AgentUsage)
    case runFinished(AgentRunOutcome)
}
