import Foundation
import Testing
@testable import AgentHarness

/// Prompt caching keyed by the conversation: Anthropic breakpoints, OpenAI Responses' cache key.
@Suite struct AgentPromptCacheTests {
    private func request(_ messages: [AgentMessage] = [.user("Q")], key: String? = "session",
                         purpose: AgentRequestIdentity.Purpose = .response) -> AgentTurnRequest {
        AgentTurnRequest(systemPrompt: "System", messages: messages, tools: [], maxOutputTokens: 4_096)
            .identified(AgentRequestIdentity(purpose: purpose)).caching(key: key)
    }

    @Test func anthropicMarksTheSystemPromptAndTheEndOfTheConversation() {
        let body = AgentWireFormat.anthropic.requestBody(
            request([.user("Q"), .assistant(text: "Looking.", toolCalls: [agentCall("c1")]),
                     .toolResult(callID: "c1", toolName: "lookup", content: "found", isError: false)]),
            model: "claude")
        let system = body["system"].array
        #expect(system.count == 1 && system[0]["text"].string == "System")
        #expect(system[0]["cache_control"]["type"].string == "ephemeral")
        let messages = body["messages"].array
        let lastBlock = messages.last?["content"].array.last
        #expect(lastBlock?["type"].string == "tool_result" && lastBlock?["cache_control"]["type"].string == "ephemeral")
        // Only the newest message carries a breakpoint.
        #expect(messages.dropLast().allSatisfy { $0["content"].array.allSatisfy { $0["cache_control"] == .null } })
    }

    @Test func aBreakpointSkipsWhatCannotCarryOne() {
        var body: [String: JSONValue] = ["system": .string(""), "messages": .array([.object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "text": .string("Answer")]),
            .object(["type": .string("thinking"), "thinking": .string("t"), "signature": .string("s")]),
            .object(["type": .string("text"), "text": .string("")])
        ])])])]
        AgentWireFormat.markAnthropicCacheBreakpoints(&body)
        let blocks = body["messages"]?.array.first?["content"].array ?? []
        #expect(blocks.map { $0["cache_control"] != .null } == [true, false, false])
        // An empty system prompt stays as it was.
        #expect(body["system"] == .string(""))
    }

    @Test func responsesNamesTheCacheAndOtherFormatsAreUnchanged() {
        #expect(AgentWireFormat.openAIResponses.requestBody(request(), model: "gpt")["prompt_cache_key"].string == "session")
        // A compatible endpoint may reject an unknown field; Gemini caches implicitly.
        #expect(AgentWireFormat.openAI.requestBody(request(), model: "gpt")["prompt_cache_key"] == .null)
        #expect(AgentWireFormat.gemini.requestBody(request(), model: "gemini")
            == AgentWireFormat.gemini.requestBody(request(key: nil), model: "gemini"))
    }

    @Test func withoutAKeyOrForASummaryNothingIsCached() {
        let plain = AgentWireFormat.anthropic.requestBody(request(key: nil), model: "claude")
        #expect(plain["system"] == .string("System"))
        #expect(plain["messages"].array.last?["content"].array.last?["cache_control"] == .null)
        let summary = request(purpose: .summary)
        #expect(AgentWireFormat.anthropic.requestBody(summary, model: "claude")["system"] == .string("System"))
        #expect(AgentWireFormat.openAIResponses.requestBody(summary, model: "gpt")["prompt_cache_key"] == .null)
    }

    @Test func theHarnessKeysEveryRequestOfARun() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("c1")]),
                                        AgentTurnResponse(text: "Done.")])
        _ = try await agentEvents(NativeHarness(model: model).cachingPrompts(key: "conversation"), tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.promptCacheKey == "conversation" })

        let unkeyed = ScriptedAgentModel([AgentTurnResponse(text: "Done.")])
        _ = try await agentEvents(NativeHarness(model: unkeyed))
        #expect(await unkeyed.requests.first?.promptCacheKey == nil)
    }
}
