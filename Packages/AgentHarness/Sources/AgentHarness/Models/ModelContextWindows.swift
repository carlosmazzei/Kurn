//
//  ModelContextWindows.swift
//  AgentHarness
//
//  Context windows of model families the app's built-in providers serve,
//  for when an endpoint omits capacity metadata. A name that matches nothing here
//  gets an explicit conservative fallback. Provider capacity metadata takes precedence.
//

import Foundation

public enum ModelContextWindows {
    public static let metadataLifetime: TimeInterval = 24 * 60 * 60

    public static func isFresh(_ timestamp: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -300 && age < metadataLifetime
    }

    public static func resolve(model: String, reported: AgentModelLimits? = nil, now: Date = Date(),
                               metadataRefresh: AgentMetadataRefresh? = nil) -> AgentContextResolution {
        let contextFresh = reported.map { isFresh($0.contextTimestamp, now: now) } ?? false
        let outputFresh = reported.map { isFresh($0.outputTimestamp, now: now) } ?? false
        let catalog = ModelContextCatalog.entry(for: model)
        let output = outputFresh ? reported?.maxOutputTokens ?? catalog?.maxOutputTokens : catalog?.maxOutputTokens
        if contextFresh, let reported, let tokens = reported.contextWindowTokens {
            let limits = AgentModelLimits(contextWindowTokens: tokens, maxOutputTokens: output,
                                          limitKind: reported.limitKind, fetchedAt: reported.contextTimestamp)
            return AgentContextResolution(contextWindowTokens: tokens, source: .api, reason: .reported,
                                          modelLimits: limits, resolvedAt: now, modelID: model).recordingMetadataRefresh(metadataRefresh)
        }
        let reason: AgentContextResolution.Reason = reported != nil && !contextFresh ? .expiredMetadata : .catalogMatch
        if let tokens = knownWindow(forModel: model) {
            let limits = AgentModelLimits(contextWindowTokens: tokens, maxOutputTokens: output, limitKind: catalog?.limitKind ?? .combined)
            return AgentContextResolution(contextWindowTokens: tokens, source: .fixedTable, reason: reason,
                                          modelLimits: limits, catalogVersion: ModelContextCatalog.version, resolvedAt: now,
                                          modelID: model).recordingMetadataRefresh(metadataRefresh)
        }
        let limits = AgentModelLimits(contextWindowTokens: nil, maxOutputTokens: outputFresh ? reported?.maxOutputTokens : nil)
        return AgentContextResolution(contextWindowTokens: unknownWindow, source: .fixedFallback,
                                      reason: reported != nil && !contextFresh ? .expiredMetadata : .unknownModel,
                                      modelLimits: limits, resolvedAt: now, modelID: model).recordingMetadataRefresh(metadataRefresh)
    }

    /// Lowercased id prefix → total context window in tokens. The longest
    /// matching prefix wins, so `gpt-4o` beats `gpt-4`. Values are the
    /// published input limits, rounded down where a vendor quotes a total
    /// that includes output.
    static let windowsByPrefix: [(prefix: String, tokens: Int)] = [
        // OpenAI
        ("gpt-4o", 128_000),
        ("chatgpt-4o", 128_000),
        ("gpt-4-turbo", 128_000),
        ("gpt-4", 8_192),
        ("gpt-3.5-turbo", 16_385),
        ("gpt-oss", 131_072),
        ("o1-mini", 128_000),
        ("o1", 200_000),
        ("o3", 200_000),
        ("o4-mini", 200_000),
        // Anthropic — every Claude 3+ model has at least 200k.
        ("claude-", 200_000),
        // Google
        ("gemini-1.0", 32_768),
        ("gemini-pro", 32_768),
        ("gemini-1.5-pro", 2_000_000),
        ("gemini-", 1_000_000),
        // Groq-hosted open models
        ("llama-3.1", 131_072),
        ("llama-3.2", 131_072),
        ("llama-3.3", 131_072),
        ("llama-4", 131_072),
        ("llama3-", 8_192),
        ("mixtral-8x7b", 32_768),
        ("gemma2", 8_192),
        ("qwen3", 131_072),
        ("qwen-qwq", 131_072),
        ("kimi-k2", 131_072),
        ("deepseek-r1-distill", 131_072)
    ]

    /// Window assumed for a model whose window nothing reports and the table does not know
    /// (typically a custom endpoint). Small on purpose: compacting early only costs a summary,
    /// while a too-large guess is caught only when the provider rejects the request.
    public static let unknownWindow = 32_768

    /// The context window the agent harness plans against: the window the provider's own model
    /// listing reported, else the table's, else `unknownWindow`. There is no
    /// practical cap: the harness compacts against the model's real window, as pi-coding-agent does.
    public static func agentWindow(reported: Int?, model: String) -> Int {
        if let reported, reported > 0 { return reported }
        return knownWindow(forModel: model) ?? unknownWindow
    }

    /// The known context window for `model`, or `nil` when the name matches
    /// no family above. Tolerates vendor-prefixed ids (`models/gemini-…`,
    /// OpenRouter's `anthropic/claude-…`, Groq's `openai/gpt-oss-…`) by
    /// matching only the last path component.
    public static func knownWindow(forModel model: String) -> Int? {
        let name = model
            .split(separator: "/")
            .last
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !name.isEmpty else { return nil }
        if let exact = ModelContextCatalog.entry(for: name) { return exact.tokens }
        // An unknown new GPT variant must not inherit the much smaller GPT-4 fallback.
        if name.hasPrefix("gpt-5") || name.hasPrefix("gpt-6") || name.hasPrefix("gpt-4.1") { return nil }
        return windowsByPrefix
            .filter { name.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .tokens
    }
}
