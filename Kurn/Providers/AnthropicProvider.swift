//
//  AnthropicProvider.swift
//  Kurn
//
//  Anthropic implementation of summary generation via the Messages API
//  (POST /v1/messages). Anthropic has no speech endpoint, so transcription is
//  unsupported and cloud transcription always routes through OpenAI Whisper.
//

import Foundation

struct AnthropicProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let model: String
    private let apiVersion = "2023-06-01"

    init(provider: AIProvider = .anthropic, apiKey: String, model: String = "claude-3-5-sonnet-latest", session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    // Transcription is unsupported: `AIProvider.supportsTranscription` is false
    // for Anthropic, so the picker never offers it, and the `LLMProvider`
    // extension's default `transcribe` covers the unreachable path.

    // MARK: - Summary (Messages API)

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let request = try makeRequest(
            timeout: LLMHTTP.summaryTimeout,
            body: [
                "model": model,
                "max_tokens": LLMHTTP.summaryMaxOutputTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ]
            ]
        )

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.summaryResult(
            from: data,
            as: MessagesResponse.self,
            emptyMessage: "empty Anthropic response",
            isTruncated: { $0.stopReason == "max_tokens" },
            extractContent: { Self.text(from: $0) }
        )
    }

    // MARK: - Chat (Messages API, plain text)

    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        // Anthropic takes the system prompt as a top-level field; the message
        // list carries only the user/assistant turns.
        let wire = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        let request = try makeRequest(
            timeout: options.timeout,
            body: [
                "model": model,
                "max_tokens": options.maxOutputTokens,
                "system": systemPrompt,
                "messages": wire
            ]
        )

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.textResult(
            from: data,
            as: MessagesResponse.self,
            emptyMessage: "empty Anthropic response",
            isTruncated: { $0.stopReason == "max_tokens" },
            extractContent: { Self.text(from: $0) }
        )
    }

    // MARK: - Helpers

    /// A Messages API request with Anthropic's auth + version headers.
    private func makeRequest(timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        try LLMHTTP.jsonRequest(
            provider: provider,
            path: "messages",
            timeout: timeout,
            headers: ["x-api-key": apiKey, "anthropic-version": apiVersion],
            body: body
        )
    }

    /// Concatenate all text blocks (there is normally one for JSON output).
    private static func text(from response: MessagesResponse) -> String {
        response.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()
    }
}

// MARK: - Response shapes

private struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }
    let content: [Block]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}
