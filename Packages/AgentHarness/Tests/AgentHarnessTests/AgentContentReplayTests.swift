import Foundation
import Testing
@testable import AgentHarness

struct AgentContentReplayTests {
    @Test(arguments: AgentWireFormat.allCases)
    func providerCopiesPreserveCanonicalDataAndPairNormalizedIDs(format: AgentWireFormat) throws {
        let call = agentCall("call/🧭", raw: "{bad")
        let message = try contentMessage([
            AgentContentBlock(id: "thinking", content: .thinking(text: "private", signature: "signed", redacted: false)),
            AgentContentBlock(id: "call", content: .toolCall(call, complete: true)),
            AgentContentBlock(id: "text", content: .text("Answer")),
            AgentContentBlock(id: "image", content: .image(mimeType: "image/png", base64: "YWJj"))
        ], api: "anthropic", model: "old-model")
        let original = try JSONEncoder().encode(message)
        let request = AgentTurnRequest(systemPrompt: "", messages: [.content(message),
            .toolResult(callID: call.id, toolName: call.name, content: "Not executed", isError: true)], tools: [], maxOutputTokens: 1)
        let prepared = format.requestProjection(request, model: "new-model")
        #expect(prepared.adjustment.normalizedCallIDs == 1 && prepared.adjustment.sanitizedArguments == 1)
        #expect(prepared.adjustment.omittedThinkingBlocks == 1 && prepared.adjustment.hasChanges)
        #expect(try JSONDecoder().decode(AgentContentMessage.self, from: original) == message)
        let body = prepared.body
        let wireID: String?
        let resultID: String?
        switch format {
        case .anthropic:
            let messages = body["messages"].array
            let blocks = messages[0]["content"].array
            wireID = blocks.first { $0["type"].string == "tool_use" }?["id"].string
            resultID = messages[1]["content"].array.first?["tool_use_id"].string
            #expect(blocks[0]["text"] == .string(AgentWireFormat.omittedThinking))
            #expect(prepared.adjustment.omittedImages == 1)
        case .openAI:
            let messages = body["messages"].array
            wireID = messages[1]["tool_calls"].array.first?["id"].string
            resultID = messages[2]["tool_call_id"].string
            #expect(messages[1]["tool_calls"].array.first?["function"]["arguments"] == .string("{}"))
        case .openAIResponses:
            let input = body["input"].array
            wireID = input.first { $0["type"].string == "function_call" }?["call_id"].string
            resultID = input.last?["call_id"].string
        case .gemini:
            let contents = body["contents"].array
            #expect(contents[0]["parts"].array[1]["functionCall"]["args"] == .object([:]))
            #expect(contents[1]["parts"].array.first?["functionResponse"]["name"] == .string("lookup"))
            wireID = "gemini-no-explicit-wire-id"
            resultID = wireID
            #expect(prepared.adjustment.omittedImages == 0)
        }
        #expect(wireID != nil && wireID == resultID && wireID != call.id)
        #expect(format.requestProjection(request, model: "new-model").body == body)
        #expect(message.toolCalls[0].rawArguments == "{bad" && message.toolCalls[0].id == call.id)
    }

    @Test(arguments: AgentWireFormat.allCases) func userImagesUseNativeWireShape(format: AgentWireFormat) throws {
        let user = try AgentContentMessage(id: "user", timestampMilliseconds: 1, role: .user,
            blocks: [AgentContentBlock(id: "text", content: .text("Look")),
                     AgentContentBlock(id: "image", content: .image(mimeType: "image/png", base64: "YWJj"))])
        let request = AgentTurnRequest(systemPrompt: "", messages: [.content(user)], tools: [], maxOutputTokens: 1)
        let prepared = format.requestProjection(request, model: "model")
        #expect(!prepared.adjustment.hasChanges)
        let encoded = try prepared.body.encodedString()
        #expect(encoded.contains("YWJj") && encoded.contains("image"))
        if format == .anthropic { #expect(prepared.body["messages"].array[0]["content"].array[1]["source"]["media_type"] == .string("image/png")) }
        if format == .gemini { #expect(prepared.body["contents"].array[0]["parts"].array[1]["inlineData"]["mimeType"] == .string("image/png")) }
    }

    @Test func signedThinkingAndOpaqueResponsesMetadataReplayOnlyToTheirModel() throws {
        let raw: JSONValue = .object(["type": .string("reasoning"), "encrypted_content": .string("encrypted"), "future": .bool(true)])
        let responses = try contentMessage([AgentContentBlock(id: "thinking", content: .thinking(text: nil, signature: "encrypted", redacted: true, metadata: raw))], api: "openAIResponses")
        let request = AgentTurnRequest(systemPrompt: "", messages: [.content(responses)], tools: [], maxOutputTokens: 1)
        #expect(AgentWireFormat.openAIResponses.requestProjection(request, model: "model").body["input"].array == [raw])
        #expect(AgentWireFormat.openAIResponses.requestProjection(request, model: "different").adjustment.omittedThinkingBlocks == 1)
        let gemini = try contentMessage([AgentContentBlock(id: "thinking", content: .thinking(text: "private", signature: "sig", redacted: false)),
            AgentContentBlock(id: "text", content: .text("Answer", signature: "text-sig"))], api: "gemini")
        let geminiRequest = AgentTurnRequest(systemPrompt: "", messages: [.content(gemini)], tools: [], maxOutputTokens: 1)
        let body = AgentWireFormat.gemini.requestProjection(geminiRequest, model: "model")
        #expect(!body.adjustment.hasChanges)
        #expect(body.body["contents"].array[0]["parts"].array[0]["thoughtSignature"] == .string("sig"))
        #expect(body.body["contents"].array[0]["parts"].array[1]["thoughtSignature"] == .string("text-sig"))
        let redacted = try contentMessage([AgentContentBlock(id: "redacted", content: .thinking(text: nil, signature: "redacted-data", redacted: true))])
        let anthropicRequest = AgentTurnRequest(systemPrompt: "", messages: [.content(redacted)], tools: [], maxOutputTokens: 1)
        #expect(AgentWireFormat.anthropic.requestProjection(anthropicRequest, model: "model").body["messages"].array[0]["content"].array[0]["data"] == .string("redacted-data"))
    }

    @Test func nativeCapacityCountsPayloadOnceAndSummaryPreservesVisibleOrder() throws {
        let call = agentCall(raw: #"{"query":"A\\nB"}"#)
        let value = try contentMessage([AgentContentBlock(id: "first", content: .text("Before")),
            AgentContentBlock(id: "call", content: .toolCall(call, complete: true)),
            AgentContentBlock(id: "second", content: .text("After"))])
        let legacy = AgentMessage.assistant(text: "BeforeAfter", toolCalls: [call])
        let estimator = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 128_000), tokenEstimator: { $0.utf8.count })
        #expect(estimator.estimateTokens(of: .content(value)) == estimator.estimateTokens(of: legacy))
        let serialized = AgentContextCompactor.serialize([.content(value)])
        #expect(serialized == "[Assistant]: Before\n\n[Assistant tool calls]: lookup(\(call.rawArguments))\n\n[Assistant]: After")
    }
}
