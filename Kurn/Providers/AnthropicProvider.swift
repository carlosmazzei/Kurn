//
//  AnthropicProvider.swift
//  Kurn
//
//  Anthropic implementation of summary generation via the Messages API
//  (POST /v1/messages). Anthropic has no speech endpoint, so transcription is
//  unsupported and cloud transcription always routes through OpenAI Whisper.
//

import AgentHarness
import Foundation
import KurnCore

struct AnthropicProvider: LLMProvider {
    let provider: AIProvider
    /// The chat's chosen reasoning level for agent turns (`ChatReasoningPreference`); nil keeps the default.
    var reasoning: AgentReasoningLevel?

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

    /// Streamed `summarize`: the same Messages request with `"stream": true`.
    func streamSummary(
        systemPrompt: String,
        userPrompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let request = try makeRequest(
            timeout: LLMHTTP.summaryTimeout,
            body: [
                "model": model,
                "max_tokens": LLMHTTP.summaryMaxOutputTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "stream": true
            ]
        )

        let accumulator = StreamingAccumulator()
        let finish = FinishReasonRecorder()
        try await LLMHTTP.streamSSE(
            request,
            session: session,
            policy: .streamingSummary,
            retriesBeforeFirstPayload: true
        ) { payload in
            guard let event = try Self.decodeEvent(from: payload) else { return }
            // `message_delta` carries the stop reason once generation ends.
            finish.record(event.delta?.stopReason)
            guard event.type == "content_block_delta", event.delta?.type == "text_delta",
                  let delta = event.delta?.text, !delta.isEmpty else { return }
            accumulator.append(delta)
            onDelta(delta)
        }
        return try LLMHTTP.summaryResult(
            streamedText: accumulator.value,
            truncated: finish.value == "max_tokens",
            emptyMessage: "empty Anthropic response"
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

    /// Concatenate all text blocks (there is normally one).
    private static func text(from response: MessagesResponse) -> String {
        response.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()
    }
}

extension AnthropicProvider: AgentModel {
    var descriptor: AgentModelDescriptor? { AgentModelDescriptor(api: "anthropic", model: model) }
    func streamTurn(
        _ request: AgentTurnRequest,
        onEvent: @escaping @Sendable (AgentModelEvent) -> Void
    ) async throws -> AgentTurnResponse {
        try await AgentModelBoundary.perform(onEvent: onEvent, classifyFailure: { LLMHTTP.agentStreamFailure($0) }, prepare: {
            try LLMHTTP.requireAPIKey(apiKey, provider: provider)
            var httpRequest = try makeRequest(timeout: LLMHTTP.chatTimeout, body: [:])
            let projection = AgentWireFormat.anthropic.requestProjection(request, model: model, reasoning: reasoning)
            if projection.adjustment.hasChanges { onEvent(.replayAdjusted(projection.adjustment)) }
            httpRequest.httpBody = Data(try projection.body.encodedString().utf8)
            return httpRequest
        }, stream: { prepared in
            try await LLMHTTP.streamAgent(prepared, session: session, format: .anthropic, identity: request.identity, onEvent: onEvent)
        })
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
        /// Present on `message_delta`: why generation stopped.
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }
    struct ErrorInfo: Decodable {
        let message: String
    }
    let type: String
    let delta: Delta?
    let error: ErrorInfo?
}
