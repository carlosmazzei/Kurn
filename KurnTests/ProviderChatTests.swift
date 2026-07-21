//
//  ProviderChatTests.swift
//  KurnTests
//
//  Drives the new `LLMProvider.chat` path through `MockURLProtocol`: each vendor
//  builds the right request (no JSON-mode forcing) and returns plain text.
//  Serialized because `MockURLProtocol` holds process-global state.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.serialized)
struct ProviderChatTests {

    // MARK: - OpenAI

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
    }

    // MARK: - Anthropic

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

    // MARK: - Google

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
}
