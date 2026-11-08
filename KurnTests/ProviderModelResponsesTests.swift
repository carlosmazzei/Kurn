import AgentHarness
import Foundation
import Testing
@testable import Kurn

struct ProviderModelResponsesTests {
    @Test func routerLimitsUseTheSmallerRoutedWindowAndPreserveOutputIndependently() throws {
        let json = """
        {"data":[{"id":"router/model","context_length":1000000,
        "top_provider":{"context_length":64000,"max_completion_tokens":4000}}]}
        """
        let result = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(result.data[0].limits.contextWindowTokens == 64_000)
        #expect(result.data[0].limits.maxOutputTokens == 4_000)
        let invalid = """
        {"data":[{"id":"router/model","context_window":"bad",
        "top_provider":{"context_length":null,"max_completion_tokens":4000}}]}
        """
        let partial = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(invalid.utf8))
        #expect(partial.data[0].limits.contextWindowTokens == nil)
        #expect(partial.data[0].limits.maxOutputTokens == 4_000)
    }

    @Test func officialOpenAIIDsStillLoadWithoutAnyCapacityFields() throws {
        let json = #"{"data":[{"id":"gpt-6.1-terra","created":1,"object":"model","owned_by":"openai"}]}"#
        let result = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(result.data[0].id == "gpt-6.1-terra")
        #expect(result.data[0].limits.contextWindowTokens == nil)
        #expect(result.data[0].limits.maxOutputTokens == nil)
        #expect(result.nextPageItem == nil)
    }

    @Test func malformedOptionalFieldsDoNotDiscardOtherLimitsOrModelIDs() throws {
        let json = #"{"data":[{"id":"claude-test","max_input_tokens":0,"max_tokens":1000}]}"#
        let result = try JSONDecoder().decode(AnthropicModelListResponse.self, from: Data(json.utf8))
        #expect(result.data[0].limits.contextWindowTokens == nil)
        #expect(result.data[0].limits.maxOutputTokens == 1_000)
        let google = #"{"models":[{"name":"plain-model","supportedGenerationMethods":[],"inputTokenLimit":"bad"}]}"#
        let model = try JSONDecoder().decode(GoogleModelListResponse.self, from: Data(google.utf8)).models[0]
        #expect(model.requestID == "plain-model")
        #expect(model.limits.contextWindowTokens == nil)
    }
}
