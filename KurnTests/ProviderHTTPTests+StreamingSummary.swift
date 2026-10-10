//
//  ProviderHTTPTests+StreamingSummary.swift
//  KurnTests
//
//  Streamed summaries: each vendor's `streamSummary` request and parse, the
//  truncation signal read from the stream's final event, and the SSE
//  transport's retry-before-first-payload rule. An extension of
//  `ProviderHTTPTests` rather than its own suite: it scripts the
//  process-global `MockURLProtocol`, and `.serialized` only orders tests
//  within one suite.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {

    private static let summaryJSON = #"{"sections":[{"title":"Recap","body":"We shipped it"}]}"#

    /// `summaryJSON` as two JSON-string-escaped fragments, the way a vendor
    /// streams it inside its own JSON envelope.
    private static let escapedHalves = (
        #"{\"sections\":[{\"title\":\"Recap\","#,
        #"\"body\":\"We shipped it\"}]}"#
    )

    // MARK: - Vendors

    @Test func openAIStreamSummaryParsesTheStreamedJSON() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"choices":[{"delta":{"content":"\#(Self.escapedHalves.0)"}}]}"#,
                #"{"choices":[{"delta":{"content":"\#(Self.escapedHalves.1)"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            ]), headers: [:])
        ])
        let provider = OpenAIProvider(apiKey: "secret", model: "gpt-test", session: MockURLProtocol.session())

        let received = StreamingAccumulator()
        let result = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "u") { received.append($0) }

        #expect(result.sections.first?.title == "Recap")
        #expect(result.sections.first?.body == "We shipped it")
        #expect(received.value == Self.summaryJSON)
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.timeoutInterval == LLMHTTP.summaryTimeout)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["stream"] as? Bool == true)
        #expect((body?["response_format"] as? [String: String])?["type"] == "json_object")
    }

    @Test func openAIStreamSummaryCutOffByTheTokenCapIsTruncation() async {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"choices":[{"delta":{"content":"{\"sections\":[{\"ti"},"finish_reason":"length"}]}"#
            ]), headers: [:])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())
        do {
            _ = try await provider.streamSummary(systemPrompt: "s", userPrompt: "u") { _ in }
            Issue.record("expected truncation")
        } catch AppError.summaryTruncated {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func anthropicStreamSummaryParsesTextDeltasAndReadsTheStopReason() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"type":"message_start"}"#,
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(Self.escapedHalves.0)"}}"#,
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(Self.escapedHalves.1)"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"{"type":"message_stop"}"#
            ]), headers: [:])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())

        let result = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "u") { _ in }

        #expect(result.sections.first?.title == "Recap")
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["stream"] as? Bool == true)
        #expect(body?["system"] as? String == "sys")
    }

    @Test func anthropicStreamSummaryStoppedAtMaxTokensIsTruncation() async {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"sec"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
            ]), headers: [:])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())
        await #expect(throws: AppError.self) {
            _ = try await provider.streamSummary(systemPrompt: "s", userPrompt: "u") { _ in }
        }
    }

    @Test func googleStreamSummaryUsesTheSSERouteAndTheSummarySchema() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"candidates":[{"content":{"parts":[{"text":"\#(Self.escapedHalves.0)"}]}}]}"#,
                #"{"candidates":[{"content":{"parts":[{"text":"\#(Self.escapedHalves.1)"}]},"finishReason":"STOP"}]}"#
            ]), headers: [:])
        ])
        let provider = GoogleProvider(apiKey: "gk", model: "gemini-test", session: MockURLProtocol.session())

        let result = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "u") { _ in }

        #expect(result.sections.first?.body == "We shipped it")
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.path.hasSuffix("models/gemini-test:streamGenerateContent") == true)
        #expect(request.url?.query?.contains("alt=sse") == true)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        let config = body?["generationConfig"] as? [String: Any]
        #expect(config?["responseMimeType"] as? String == "application/json")
        #expect(config?["responseJsonSchema"] != nil)
    }

    @Test func googleStreamSummaryFinishedAtMaxTokensIsTruncation() async {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([
                #"{"candidates":[{"content":{"parts":[{"text":"{\"sec"}]},"finishReason":"MAX_TOKENS"}]}"#
            ]), headers: [:])
        ])
        let provider = GoogleProvider(apiKey: "gk", session: MockURLProtocol.session())
        await #expect(throws: AppError.self) {
            _ = try await provider.streamSummary(systemPrompt: "s", userPrompt: "u") { _ in }
        }
    }

    @Test func anEmptyStreamedSummaryIsADecodingError() async {
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#]), headers: [:])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())
        do {
            _ = try await provider.streamSummary(systemPrompt: "s", userPrompt: "u") { _ in }
            Issue.record("expected a decoding error")
        } catch AppError.decodingError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Retry before the first payload

    private func streamRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        return request
    }

    @Test func aStreamRejectedBeforeItsFirstPayloadIsRetried() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "busy"]], status: 503),
            .failure(URLError(.cannotConnectToHost)),
            .success(status: 200, body: sseBody(["one", "two"]), headers: [:])
        ])
        let clock = ManualSleepClock()
        let payloads = Recorded<String>()
        try await LLMHTTP.streamSSE(
            streamRequest(),
            session: MockURLProtocol.session(),
            policy: .streamingSummary,
            clock: clock,
            retriesBeforeFirstPayload: true
        ) { payloads.append($0) }

        #expect(payloads.values == ["one", "two"])
        #expect(MockURLProtocol.capturedRequests.count == 3)
        #expect(clock.durations.count == 2)
    }

    @Test func aStreamIsNeverRetriedOnceAPayloadArrived() async {
        struct Rejected: Error {}
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody(["one", "two"]), headers: [:]),
            .success(status: 200, body: sseBody(["again"]), headers: [:])
        ])
        let clock = ManualSleepClock()
        await #expect(throws: Rejected.self) {
            try await LLMHTTP.streamSSE(
                streamRequest(),
                session: MockURLProtocol.session(),
                policy: .streamingSummary,
                clock: clock,
                retriesBeforeFirstPayload: true
            ) { payload in
                if payload == "two" { throw Rejected() }
            }
        }
        #expect(MockURLProtocol.capturedRequests.count == 1)
        #expect(clock.durations.isEmpty)
    }

    @Test func aStreamFailsFastWithoutTheRetryOptIn() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "busy"]], status: 503),
            .success(status: 200, body: sseBody(["one"]), headers: [:])
        ])
        await #expect(throws: AppError.self) {
            try await LLMHTTP.streamSSE(
                streamRequest(),
                session: MockURLProtocol.session(),
                policy: .streamingSummary,
                clock: ManualSleepClock()
            ) { _ in }
        }
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func retryDelayFollowsTheBufferedTransportsRules() {
        let policy = HTTPPolicy.streamingSummary
        func delay(_ error: Error, retryAfter: TimeInterval? = nil, attempt: Int = 0) -> TimeInterval? {
            LLMHTTP.retryDelayBeforeFirstPayload(after: error, attempt: attempt, retryAfter: retryAfter, policy: policy)
        }
        #expect(delay(AppError.apiError(statusCode: 503, message: "busy"), retryAfter: 2) == 2)
        #expect(delay(AppError.apiError(statusCode: 429, message: "slow"), retryAfter: 301) == nil)
        #expect(delay(AppError.apiError(statusCode: 400, message: "bad")) == nil)
        #expect(delay(AppError.apiError(statusCode: 0, message: "stream error")) == nil)
        #expect(delay(AppError.apiError(statusCode: 503, message: "busy"), attempt: LLMHTTP.maxAttempts - 1) == nil)
        #expect(delay(AppError.networkError(URLError(.cannotConnectToHost))) != nil)
        #expect(delay(AppError.networkError(URLError(.timedOut))) == nil)
        #expect(delay(AppError.summaryTruncated) == nil)
    }

    @Test func streamingSummaryPolicyIsBoundedBySilenceNotLength() {
        let policy = HTTPPolicy.streamingSummary
        #expect(policy.idleTimeout == LLMHTTP.summaryTimeout)
        #expect(policy.totalDeadline == LLMHTTP.summaryStreamDeadline)
        #expect(policy.totalDeadline > policy.idleTimeout)
        #expect(HTTPPolicy(totalDeadline: 60).idleTimeout == 60)
        #expect(HTTPPolicy(totalDeadline: 60, idleTimeout: 600).idleTimeout == 60)
    }
}
