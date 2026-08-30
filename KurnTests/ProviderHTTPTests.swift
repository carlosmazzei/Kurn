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
import KurnCore
import Testing
@testable import Kurn

@Suite(.serialized)
struct ProviderHTTPTests {

    let sectionsBody = #"{"sections":[{"title":"Recap","body":"We shipped it"}]}"#

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
        #expect(body?["max_completion_tokens"] as? Int == LLMHTTP.summaryMaxOutputTokens)
        #expect(request.timeoutInterval == LLMHTTP.summaryTimeout)
    }

    @Test func openAITruncatedSummaryThrowsSummaryTruncated() async {
        // finish_reason "length" means the JSON payload was cut off by the
        // output-token cap; the specific error must surface, not a decode error.
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "choices": [["message": ["content": #"{"sections":[{"ti"#], "finish_reason": "length"]]
            ])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected an error")
        } catch AppError.summaryTruncated {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
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
        #expect(request.value(forHTTPHeaderField: "X-Client-Request-Id") == nil)
        let bodyString = String(bytes: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
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

    @Test func transcribeUsesSelectedProviderBaseURLAndModel() async throws {
        // A non-OpenAI OpenAI-compatible provider (Groq) must hit its own
        // `/audio/transcriptions` endpoint with its own Whisper model, proving
        // the transcription path is provider-driven rather than hardcoded.
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["text": "olá", "language": "pt"])
        ])
        let provider = OpenAIProvider(
            provider: .groq,
            apiKey: "groq-secret",
            transcriptionModel: "whisper-large-v3",
            session: MockURLProtocol.session()
        )

        _ = try await provider.transcribe(
            audioData: Data([1, 2, 3]), fileName: "clip.m4a", language: .portuguese
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer groq-secret")
        #expect(request.value(forHTTPHeaderField: "X-Client-Request-Id") == nil)
        let bodyString = String(bytes: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
        #expect(bodyString.contains("whisper-large-v3"))
        #expect(!bodyString.contains("whisper-1"))
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

    @Test func anthropicTruncatedSummaryThrowsSummaryTruncated() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "content": [["type": "text", "text": #"{"sections":[{"ti"#]],
                "stop_reason": "max_tokens"
            ])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected an error")
        } catch AppError.summaryTruncated {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func anthropicDoesNotSupportTranscription() async {
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())
        await #expect(throws: AppError.self) {
            _ = try await provider.transcribe(audioData: Data(), fileName: "a.m4a", language: .english)
        }
    }

    // MARK: - Google

    @Test func googleSummarizePassesKeyHeaderAndParsesCandidates() async throws {
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
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        let generationConfig = body?["generationConfig"] as? [String: Any]
        #expect(generationConfig?["responseMimeType"] as? String == "application/json")
        #expect(generationConfig?["responseJsonSchema"] != nil)
    }

    @Test func googleTruncatedSummaryThrowsSummaryTruncated() async {
        // A MAX_TOKENS candidate may omit its content block entirely; decoding
        // must still succeed so the truncation check runs.
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["candidates": [["finishReason": "MAX_TOKENS"]]])
        ])
        let provider = GoogleProvider(apiKey: "gk", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected an error")
        } catch AppError.summaryTruncated {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Provider models listing (ProviderModelsService)

    // Lives in this suite (not its own) because it scripts the process-global
    // MockURLProtocol: `.serialized` only orders tests WITHIN a suite, and a
    // separate suite would race this one for the scripted stubs.
    @Test func googleModelsSendsKeyHeaderNotQuery() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "models": [
                    [
                        "name": "models/gemini-1.5-pro",
                        "baseModelId": NSNull(),
                        "supportedGenerationMethods": ["generateContent"]
                    ]
                ]
            ])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "gk")
        let models = try await service.models(for: .google)
        #expect(models.contains("gemini-1.5-pro"))

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk")
    }

    @Test func groqModelsFallsBackToKnownListOn403() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "Forbidden"]], status: 403)
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "groq-secret")
        let models = try await service.models(for: .groq)
        #expect(models.contains("llama-3.3-70b-versatile"))
        #expect(models.contains("whisper-large-v3"))

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer groq-secret")
    }

    @Test func groqModelsFallsBackToKnownListWhenEmpty() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["data": []])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "groq-secret")
        let models = try await service.models(for: .groq)
        #expect(models.contains("llama-3.1-8b-instant"))
        #expect(models.contains("whisper-large-v3-turbo"))
    }

    @Test func groqModelsReturnsAPIResponseWhenAvailable() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "data": [
                    ["id": "llama-3.3-70b-versatile", "active": true],
                    ["id": "custom-groq-model", "active": true]
                ]
            ])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "groq-secret")
        let models = try await service.models(for: .groq)
        #expect(models.contains("custom-groq-model"))
        #expect(models.contains("llama-3.3-70b-versatile"))
    }

    @Test func openAIModelsDoesNotFallBackOn403() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "Invalid auth"]], status: 401)
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "secret")
        await #expect(throws: AppError.self) {
            _ = try await service.models(for: .openAI)
        }
    }

    @Test func groqModelsDoesNotFallBackOn401() async throws {
        // Unlike the documented 403 quirk, a 401 means the key itself is
        // wrong/revoked — that must still surface as an error instead of
        // silently showing the static fallback list.
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "Invalid API key"]], status: 401)
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "bad-groq-key")
        await #expect(throws: AppError.self) {
            _ = try await service.models(for: .groq)
        }
    }

    // MARK: - Chat (plain-text LLMProvider.chat)

    // These live in this suite (not their own) for the same reason as the
    // ProviderModelsService tests above: they script the process-global
    // MockURLProtocol, and `.serialized` only orders tests WITHIN a suite — a
    // separate suite would run in parallel and race this one for the stubs.

    @Test func openAIChatSendsMessagesAndReturnsText() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": "The decision was to ship."]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", model: "gpt-test", session: MockURLProtocol.session())

        let reply = try await provider.chat(
            systemPrompt: "ground",
            messages: [ChatMessage(role: .user, content: "What did we decide?")]
        )
        #expect(reply == "The decision was to ship.")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        // Chat must NOT force JSON mode (that's the summary path).
        #expect(body?["response_format"] == nil)
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["content"] == "What did we decide?")
        #expect(body?["max_completion_tokens"] as? Int == LLMHTTP.chatMaxOutputTokens)
        #expect(body?["reasoning_effort"] == nil)
    }

    @Test func openAIGPT5ChatUsesLowReasoningEffort() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": "Resposta."]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", model: "gpt-5.4", session: MockURLProtocol.session())

        _ = try await provider.chat(
            systemPrompt: "ground",
            messages: [ChatMessage(role: .user, content: "O que foi decidido?")]
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["reasoning_effort"] as? String == "low")
        #expect(body?["max_completion_tokens"] as? Int == 4096)
    }

    @Test func openAIDocumentGenerationUsesLongOutputBudget() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": "# Document"]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", model: "gpt-5.4", session: MockURLProtocol.session())

        _ = try await provider.chat(
            systemPrompt: "ground",
            messages: [ChatMessage(role: .user, content: "Create a document")],
            options: .document
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["max_completion_tokens"] as? Int == 8192)
        #expect(request.timeoutInterval == LLMHTTP.summaryTimeout)
    }

    @Test func truncatedChatResponseThrowsSpecificError() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "choices": [[
                    "message": ["content": NSNull()],
                    "finish_reason": "length"
                ]]
            ])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        do {
            _ = try await provider.chat(
                systemPrompt: "s",
                messages: [ChatMessage(role: .user, content: "q")]
            )
            Issue.record("Expected generationTruncated")
        } catch AppError.generationTruncated {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func openAIChatReturnsRefusalWhenContentIsNull() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "choices": [["message": ["content": NSNull(), "refusal": "I cannot answer that."]]]
            ])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let reply = try await provider.chat(
            systemPrompt: "ground",
            messages: [ChatMessage(role: .user, content: "question")]
        )

        #expect(reply == "I cannot answer that.")
    }

    @Test func anthropicChatUsesSystemFieldAndReturnsText() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["content": [["type": "text", "text": "Grounded answer."]]])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())

        let reply = try await provider.chat(
            systemPrompt: "ground",
            messages: [ChatMessage(role: .user, content: "hi")]
        )
        #expect(reply == "Grounded answer.")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["system"] as? String == "ground")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] == "user")
    }

    @Test func googleChatFoldsSystemIntoUserTurnAndReturnsText() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "candidates": [["content": ["parts": [["text": "Gemini reply."]]]]]
            ])
        ])
        let provider = GoogleProvider(apiKey: "gk", session: MockURLProtocol.session())

        let reply = try await provider.chat(
            systemPrompt: "SYS-PROMPT",
            messages: [ChatMessage(role: .user, content: "USER-Q")]
        )
        #expect(reply == "Gemini reply.")

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString.contains("generateContent") == true)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        // No JSON mime forcing on the chat path.
        let generationConfig = body?["generationConfig"] as? [String: Any]
        #expect(generationConfig?["responseMimeType"] == nil)
        // System prompt folded into the first user turn.
        let contents = body?["contents"] as? [[String: Any]]
        let firstParts = (contents?.first?["parts"] as? [[String: String]])
        let firstText = firstParts?.first?["text"] ?? ""
        #expect(firstText.contains("SYS-PROMPT"))
        #expect(firstText.contains("USER-Q"))
    }

    @Test func emptyChatResponseThrows() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": ""]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())
        await #expect(throws: AppError.self) {
            _ = try await provider.chat(systemPrompt: "s", messages: [ChatMessage(role: .user, content: "q")])
        }
    }

    // MARK: - LLMTranscriptCorrector.requestCorrections network shape

    @Test func llmTranscriptCorrectorSendsIdsAndParsesReply() async throws {
        let a = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "we ned to ship", confidence: 0.3)
        let b = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 1, endTime: 2, text: "this is fine", confidence: 0.4)

        let replyJSON = """
        {"segments":[{"id":"\(a.id.uuidString)","text":"we need to ship"},{"id":"\(b.id.uuidString)","text":"this is fine"}]}
        """
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": replyJSON]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let corrections = await LLMTranscriptCorrector().requestCorrections(
            for: [a, b], vocabulary: ["ship"], language: .english, llm: provider
        )

        #expect(corrections[a.id] == "we need to ship")
        #expect(corrections[b.id] == "this is fine")

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        let userMessage = messages?.last?["content"] ?? ""
        #expect(userMessage.contains(a.id.uuidString))
        #expect(userMessage.contains(b.id.uuidString))
        #expect(userMessage.contains("ship"))
    }

    @Test func llmTranscriptCorrectorFailsOpenOnTransportError() async {
        MockURLProtocol.enqueue([.failure(URLError(.notConnectedToInternet))])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())
        let a = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "hello", confidence: 0.3)

        let corrections = await LLMTranscriptCorrector().requestCorrections(
            for: [a], vocabulary: [], language: .autoDetect, llm: provider
        )
        #expect(corrections.isEmpty)
    }
}
