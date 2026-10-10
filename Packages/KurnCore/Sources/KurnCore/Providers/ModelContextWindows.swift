//
//  ModelContextWindows.swift
//  KurnCore
//
//  Context windows of model families the app's built-in providers serve,
//  for when the provider's own `/models` listing does not report one
//  (OpenAI and Anthropic list ids only). A name that matches nothing here
//  gets `ContextBudget.conservative`, and a window that turns out to be
//  wrong is caught by the provider rejecting the request, which falls back
//  to the staged path — so this table is an optimisation, never a contract.
//

import Foundation

public enum ModelContextWindows {
    /// Lowercased id prefix → total context window in tokens. The longest
    /// matching prefix wins, so `gpt-4o` beats `gpt-4`. Values are the
    /// published input limits, rounded down where a vendor quotes a total
    /// that includes output.
    static let windowsByPrefix: [(prefix: String, tokens: Int)] = [
        // OpenAI
        ("gpt-5", 272_000),
        ("gpt-4.1", 1_000_000),
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
        return windowsByPrefix
            .filter { name.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .tokens
    }
}
