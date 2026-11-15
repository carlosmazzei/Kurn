import Foundation
import Testing
@testable import AgentHarness

/// The host's reasoning level, mapped per vendor and left out of summary requests.
@Suite struct AgentReasoningLevelTests {
    private func request(maxOutputTokens: Int = 32_000, purpose: AgentRequestIdentity.Purpose? = nil) -> AgentTurnRequest {
        let plain = AgentTurnRequest(systemPrompt: "S", messages: [.user("Q")], tools: [], maxOutputTokens: maxOutputTokens)
        return purpose.map { plain.identified(AgentRequestIdentity(purpose: $0)) } ?? plain
    }

    @Test func eachVendorGetsItsOwnShape() {
        let anthropic = AgentWireFormat.anthropic.requestBody(request(), model: "claude", reasoning: .medium)
        #expect(anthropic["thinking"]["type"].string == "enabled" && anthropic["thinking"]["budget_tokens"].int == 8_192)

        let gemini = AgentWireFormat.gemini.requestBody(request(), model: "gemini", reasoning: .high)
        let thinking = gemini["generationConfig"]["thinkingConfig"]
        #expect(thinking["includeThoughts"] == .bool(true) && thinking["thinkingBudget"].int == 24_576)
        #expect(gemini["generationConfig"]["maxOutputTokens"].int == 32_000)

        let responses = AgentWireFormat.openAIResponses.requestBody(request(), model: "gpt", reasoningEffort: "low", reasoning: .high)
        #expect(responses["reasoning"]["effort"].string == "high" && responses["reasoning"]["summary"].string == "auto")

        let chat = AgentWireFormat.openAI.requestBody(request(), model: "gpt", reasoning: .low)
        #expect(chat["reasoning_effort"].string == "low")
    }

    @Test func withoutALevelTheRequestIsUnchanged() {
        #expect(AgentWireFormat.anthropic.requestBody(request(), model: "c")["thinking"] == .null)
        #expect(AgentWireFormat.gemini.requestBody(request(), model: "g")["generationConfig"]["thinkingConfig"] == .null)
        // OpenAI's fixed default effort still goes out, without asking for a visible summary.
        let responses = AgentWireFormat.openAIResponses.requestBody(request(), model: "gpt", reasoningEffort: "low")
        #expect(responses["reasoning"]["effort"].string == "low" && responses["reasoning"]["summary"] == .null)
    }

    @Test func summaryRequestsNeverReason() {
        let summary = request(purpose: .summary)
        #expect(AgentWireFormat.anthropic.requestBody(summary, model: "c", reasoning: .high)["thinking"] == .null)
        #expect(AgentWireFormat.openAIResponses.requestBody(summary, model: "g", reasoning: .high)["reasoning"] == .null)
        // A normal or wrap-up request keeps it.
        #expect(AgentWireFormat.anthropic.requestBody(request(purpose: .wrapUp), model: "c", reasoning: .low)["thinking"] != .null)
    }

    @Test func theBudgetFitsTheOutputLimit() {
        #expect(AgentReasoningLevel.high.thinkingBudget(maxOutputTokens: 10_000) == 9_999)
        #expect(AgentReasoningLevel.low.thinkingBudget(maxOutputTokens: 1_024) == nil)
        #expect(AgentReasoningLevel.low.thinkingBudget(maxOutputTokens: 1_025) == 1_024)
        let small = AgentWireFormat.anthropic.requestBody(request(maxOutputTokens: 800), model: "c", reasoning: .high)
        #expect(small["thinking"] == .null)
    }
}
