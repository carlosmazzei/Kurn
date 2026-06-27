//
//  ProviderHTTPTests.swift
//  KurnTests
//
//  Drives the cloud providers through `MockURLProtocol`, asserting on the
//  request they build (URL, headers, body) and how they parse responses, plus
//  the shared error-mapping and retry behavior in `LLMHTTP`. No network is
//  touched. Serialized because `MockURLProtocol` holds process-global state.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.serialized)
struct ProviderHTTPTests {

    private let sectionsBody = #"{"sections":[{"title":"Recap","body":"We shipped it"}]}"#

    // MARK: - OpenAI

    @Test func openAISummarizeBuildsChatRequestAndParsesSections() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": sectionsBody]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", model: "gpt-test", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "sys", userPrompt: "usr")
        #expect(result.sections.count == 1)
        #expect(result.sections.first?.title == "Recap")
        #expect(result.sections.first?.body == "We shipped it")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-test")
        #expect(body?["messages"] != nil)
    }

    @Test func openAITranscribeUploadsMultipartAndParsesSegments() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "text": "hello world",
                "language": "en",
                "segments": [
                    ["start": 0.0, "end": 1.5, "text": " hello"],
                    ["start": 1.5, "end": 3.0, "text": " world"]
                ]
            ])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let raw = try await provider.transcribe(
            audioData: Data([1, 2, 3]), fileName: "clip.m4a", language: .english
        )
        #expect(raw.spans.count == 2)
        #expect(raw.spans.first?.text == "hello") // provider trims surrounding space
        #expect(raw.language == "en")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString.contains("audio/transcriptions") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let bodyString = String(decoding: MockURLProtocol.body(of: request), as: UTF8.self)
        #expect(bodyString.contains("whisper-1"))
        #expect(bodyString.contains("verbose_json"))
        #expect(bodyString.contains("en")) // language hint field
    }

    @Test func openAITranscribeFallsBackToSingleSpanWithoutSegments() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["text": "whole blob", "language": "pt"])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let raw = try await provider.transcribe(
            audioData: Data([1]), fileName: "clip.m4a", language: .autoDetect
        )
        #expect(raw.spans.count == 1)
        #expect(raw.spans.first?.text == "whole blob")
    }

    // MARK: - Anthropic

    @Test func anthropicSummarizeSendsVersionHeaderAndParsesContent() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "content": [["type": "text", "text": #"{"sections":[{"title":"Decisions","items":["Ship it"]}]}"#]]
            ])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.first?.title == "Decisions")
        #expect(result.sections.first?.items == ["Ship it"])

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "ak")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func anthropicDoesNotSupportTranscription() async {
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())
        await #expect(throws: AppError.self) {
            _ = try await provider.transcribe(audioData: Data(), fileName: "a.m4a", language: .english)
        }
    }

    // MARK: - Google

    @Test func googleSummarizePassesKeyQueryAndParsesCandidates() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "candidates": [["content": ["parts": [["text": #"{"sections":[{"title":"Summary","body":"ok"}]}"#]]]]]
            ])
        ])
        let provider = GoogleProvider(apiKey: "gk", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.first?.title == "Summary")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString.contains("generateContent") == true)
        #expect(request.url?.query?.contains("key=gk") == true)
    }

    // MARK: - Error mapping & retry (shared LLMHTTP)

    @Test func apiErrorSurfacesStatusAndVendorMessage() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "bad key"]], status: 401)
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected an error")
        } catch let AppError.apiError(status, message) {
            #expect(status == 401)
            #expect(message == "bad key")
        }
    }

    @Test func malformedSummaryContentThrowsDecodingError() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": "this is not json"]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        await #expect(throws: AppError.self) {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test func rateLimitIsRetriedThenSucceeds() async throws {
        // First a 429 with a short Retry-After, then a success — the shared retry
        // loop should transparently recover. Retry-After is honored, so the wait
        // is tiny and the test stays fast.
        MockURLProtocol.enqueue([
            .success(
                status: 429,
                body: Data(#"{"error":{"message":"slow down"}}"#.utf8),
                headers: ["Retry-After": "0.05"]
            ),
            MockURLProtocol.json(["choices": [["message": ["content": sectionsBody]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.first?.title == "Recap")
        #expect(MockURLProtocol.capturedRequests.count == 2)
    }
}
