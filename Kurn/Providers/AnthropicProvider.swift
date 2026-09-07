//
//  AnthropicProvider.swift
//  Kurn
//
//  Anthropic implementation of summary generation via the Messages API
//  (POST /v1/messages). Anthropic has no speech endpoint, so transcription is
//  unsupported and cloud transcription always routes through OpenAI Whisper.
//

import Foundation
import KurnCore

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

    // MARK: - Chat (Messages API, streaming)

    @discardableResult
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> TokenUsage? {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let wire = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        let request = try makeRequest(
            timeout: options.timeout,
            body: [
                "model": model,
                "max_tokens": options.maxOutputTokens,
                "system": systemPrompt,
                "messages": wire,
                "stream": true
            ]
        )

        let accumulator = StreamingAccumulator()
        let usage = UsageAccumulator()
        try await LLMHTTP.streamSSE(
            request,
            session: session,
            policy: .interactive(totalDeadline: options.timeout)
        ) { payload in
            guard let event = try Self.decodeEvent(from: payload) else { return }
            // `message_start` carries the prompt's input_tokens up front;
            // `message_delta` reports the cumulative output_tokens once the
            // generation is done — different events, so each is applied to
            // the accumulator independently rather than requiring both.
            if let inputTokens = event.message?.usage?.inputTokens {
                usage.set(promptTokens: inputTokens)
            }
            if let outputTokens = event.usage?.outputTokens {
                usage.set(completionTokens: outputTokens)
            }
            guard event.type == "content_block_delta", event.delta?.type == "text_delta",
                  let delta = event.delta?.text, !delta.isEmpty else { return }
            accumulator.append(delta)
            onDelta(delta)
        }
        guard accumulator.receivedText else {
            throw AppError.decodingError("empty Anthropic response")
        }
        return usage.value
    }

    /// One decoded SSE event. Anthropic's stream carries several event types
    /// (`message_start`, `content_block_delta`, `message_delta`,
    /// `message_stop`, `ping`, …); callers pick out the fields they need. A
    /// mid-stream `error` event is surfaced by throwing rather than
    /// returning it for the caller to notice, so it fails the answer instead
    /// of being silently dropped.
    private static func decodeEvent(from payload: String) throws -> StreamEvent? {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { return nil }
        if event.type == "error" {
            throw AppError.apiError(statusCode: 0, message: event.error?.message ?? "stream error")
        }
        return event
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

/// One SSE event from a streaming Messages API response (`"stream": true`).
/// Only the fields streaming needs — `delta.text` for `content_block_delta`,
/// `error.message` for a mid-stream `error` event, and `usage` at both the
/// top level (`message_delta`) and nested under `message`
/// (`message_start`), Anthropic's two different places token counts arrive.
private struct StreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    struct ErrorInfo: Decodable {
        let message: String
    }
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
    struct MessageInfo: Decodable {
        let usage: Usage?
    }
    let type: String
    let delta: Delta?
    let error: ErrorInfo?
    let message: MessageInfo?
    let usage: Usage?
}
