import Testing
@testable import Kurn

struct StructuredExtractionRequestTests {
    private let extraction = TextGenerationOptions.knowledgeExtraction(for: .openAI)

    @Test func openAIAndGroqAskForJSONOnlyForStructuredExtraction() {
        #expect(OpenAIProvider.jsonResponseFormat(extraction, providerID: AIProvider.openAI.id)?["type"] as? String == "json_object")
        #expect(OpenAIProvider.jsonResponseFormat(extraction, providerID: AIProvider.groq.id) != nil)
        #expect(OpenAIProvider.jsonResponseFormat(.chat, providerID: AIProvider.openAI.id) == nil)
        #expect(OpenAIProvider.jsonResponseFormat(extraction, providerID: "custom-endpoint") == nil)
    }

    @Test func geminiSetsTheJSONMimeTypeOnlyForStructuredExtraction() {
        #expect(GoogleProvider.generationConfig(extraction)["responseMimeType"] as? String == "application/json")
        #expect(GoogleProvider.generationConfig(.document)["responseMimeType"] == nil)
        #expect(GoogleProvider.generationConfig(.document)["maxOutputTokens"] as? Int == TextGenerationOptions.document.maxOutputTokens)
    }

    @Test func anthropicCachesTheExtractionSystemPromptOnly() {
        let cached = AnthropicProvider.systemField("system", extraction) as? [[String: Any]]
        #expect(cached?.first?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        #expect(AnthropicProvider.systemField("system", .document) as? String == "system")
    }

    @Test func reasoningModelsGetLowEffort() {
        #expect(OpenAIProvider.usesLowReasoningEffort("gpt-6.1-terra"))
        #expect(OpenAIProvider.usesLowReasoningEffort("gpt-5.4"))
        #expect(!OpenAIProvider.usesLowReasoningEffort("gpt-4o-mini"))
    }

    @Test func jsonModeMentionsJSONInTheInputMessage() {
        let wire = [["role": "system", "content": "s"], ["role": "user", "content": "segments"]]
        let reminded = OpenAIProvider.withJSONReminder(wire)
        #expect(reminded[0]["content"] == "s")
        #expect(reminded[1]["content"]?.contains("JSON") == true)
        #expect(OpenAIProvider.withJSONReminder([["role": "system", "content": "s"]]).last?["role"] == "user")
    }
}
