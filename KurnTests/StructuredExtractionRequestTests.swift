import Foundation
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

    @Test func extractionBudgetFollowsTheModelOutputLimitWithinTheCap() {
        let terra = TextGenerationOptions.knowledgeExtraction(for: .openAI, modelOutputLimit: 128_000)
        #expect(terra.maxOutputTokens == TextGenerationOptions.knowledgeExtractionOutputCap)
        #expect(terra.timeout == 600)
        let unknown = TextGenerationOptions.knowledgeExtraction(for: .openAI, modelOutputLimit: nil)
        #expect(unknown.maxOutputTokens == TextGenerationOptions.document.maxOutputTokens)
        #expect(unknown.timeout == TextGenerationOptions.document.timeout)
        let small = TextGenerationOptions.knowledgeExtraction(for: .openAI, modelOutputLimit: 4_096)
        #expect(small.maxOutputTokens == 4_096)
        #expect(TextGenerationOptions.knowledgeExtraction(for: .appleOnDevice, modelOutputLimit: 128_000).maxOutputTokens == 1_024)
    }

    @Test func segmentAliasesRoundTripOnlyInSegmentReferenceFields() throws {
        let sources = [KnowledgeExtractionPrompt.Source(id: "uuid-a", speaker: "A", startMs: 0, endMs: 1, text: "x"),
                       KnowledgeExtractionPrompt.Source(id: "uuid-b", speaker: "B", startMs: 1, endMs: 2, text: "y")]
        let aliases = KnowledgeExtractionService.aliases(for: sources)
        #expect(KnowledgeExtractionService.aliased(sources, aliases).map(\.id) == ["s1", "s2"])
        let reply: [String: Any] = ["examinedSegmentIDs": ["s1", "s2"], "entities": [["ref": "s1", "name": "s2"]],
            "assertions": [["attributedToSegmentID": "s2", "subject": "s1", "evidence": [["segmentIDs": ["s1", "s9"], "quote": "s1"]]]]]
        let mapped = try #require(try JSONSerialization.jsonObject(
            with: KnowledgeExtractionService.dealiased(JSONSerialization.data(withJSONObject: reply), aliases: aliases)) as? [String: Any])
        #expect(mapped["examinedSegmentIDs"] as? [String] == ["uuid-a", "uuid-b"])
        let assertion = try #require((mapped["assertions"] as? [[String: Any]])?.first)
        #expect(assertion["attributedToSegmentID"] as? String == "uuid-b")
        #expect(assertion["subject"] as? String == "s1")
        let evidence = try #require((assertion["evidence"] as? [[String: Any]])?.first)
        #expect(evidence["segmentIDs"] as? [String] == ["uuid-a", "s9"])
        #expect(evidence["quote"] as? String == "s1")
        #expect((mapped["entities"] as? [[String: Any]])?.first?["ref"] as? String == "s1")
    }

    @Test func usageIsParsedFromEveryVendorShapeAndOnlyRecordedInsideASink() {
        func body(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        #expect(TokenUsageRecording.parse(body(["usage": ["prompt_tokens": 10, "completion_tokens": 4]]))
            == TokenUsage(promptTokens: 10, completionTokens: 4))
        #expect(TokenUsageRecording.parse(body(["usage": ["input_tokens": 7, "output_tokens": 3]]))
            == TokenUsage(promptTokens: 7, completionTokens: 3))
        #expect(TokenUsageRecording.parse(body(["usageMetadata": ["promptTokenCount": 5, "candidatesTokenCount": 2]]))
            == TokenUsage(promptTokens: 5, completionTokens: 2))
        #expect(TokenUsageRecording.parse(body(["choices": []])) == nil)
        let sink = TokenUsageSink()
        TokenUsageRecording.$sink.withValue(sink) {
            TokenUsageRecording.record(responseBody: body(["usage": ["prompt_tokens": 1, "completion_tokens": 1]]))
            TokenUsageRecording.record(responseBody: body(["usage": ["input_tokens": 2, "output_tokens": 3]]))
        }
        TokenUsageRecording.record(responseBody: body(["usage": ["prompt_tokens": 100, "completion_tokens": 100]]))
        #expect(sink.total == TokenUsage(promptTokens: 3, completionTokens: 4))
    }
}
