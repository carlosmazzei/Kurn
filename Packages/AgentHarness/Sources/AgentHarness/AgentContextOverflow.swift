import Foundation

/// Provider-neutral overflow classification shared by agent and generation requests.
public enum AgentContextOverflow {
    public static func matches(statusCode: Int, message: String) -> Bool {
        let text = message.lowercased()
        if nonOverflowMarkers.contains(where: { text.contains($0) }) { return false }
        if statusCode == 413 { return true }
        guard [0, 400, 422].contains(statusCode) else { return false }
        return contextOverflowMarkers.contains { text.contains($0) }
    }

    /// Phrases vendors use for an over-long input, after pi-ai's overflow patterns: OpenAI
    /// ("exceeds the context window", `context_length_exceeded`), Anthropic ("prompt is too long",
    /// `request_too_large`), Gemini ("input token count … exceeds the maximum number of tokens"),
    /// Groq ("reduce the length of the messages"), OpenRouter and Mistral ("maximum context
    /// length"), xAI ("maximum prompt length"), Bedrock, GitHub Copilot, llama.cpp, LM Studio,
    /// MiniMax, Kimi, Ollama and z.ai.
    static let contextOverflowMarkers = [
        "context length",
        "context_length",
        "context window",
        "prompt is too long",
        "prompt too long",
        "request_too_large",
        "input is too long",
        "input token count",
        "maximum number of tokens",
        "maximum prompt length",
        "too many tokens",
        "token limit exceeded",
        "exceeded model token limit",
        "reduce the length",
        "exceeds the limit of",
        "exceeds the available context size",
        "greater than the context length",
        "model_context_window_exceeded"
    ]

    /// Rate limiting and throttling can share wording with an overflow ("Too many tokens, please
    /// wait"), and retrying them after a compaction would only discard context.
    static let nonOverflowMarkers = [
        "rate limit",
        "too many requests",
        "throttl",
        "please wait"
    ]
}

/// The host maps its transport errors to this contract without coupling the runtime
/// to an application error type. Unclassified errors propagate normally.
public protocol AgentContextOverflowError: Error {
    var isContextOverflow: Bool { get }
}

/// The context could not be reduced enough for the model (NH06): the provider rejected the
/// request as too long and no usable summary could replace the older part — the summary was cut
/// off, unusable, or its own request was too long. The run ends here instead of continuing on a
/// note that would stand in for a summary; nothing of the failed attempt is reused.
public struct AgentContextReductionError: Error, Sendable, Equatable {
    public init() {}
}
