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
}
