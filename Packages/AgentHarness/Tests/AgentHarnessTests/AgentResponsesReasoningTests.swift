import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentResponsesReasoningTests {
    let reasoning: JSONValue = .object([
        "id": .string("rs_1"), "type": .string("reasoning"), "summary": .array([]),
        "encrypted_content": .string("opaque-encrypted-content"), "future_field": .bool(true)
    ])

    var metadata: JSONValue { .object(["openAIResponses": .object(["reasoning": .array([reasoning])])]) }

    @Test(arguments: [false, true]) func reasoningSurvivesHarnessFollowup(fromCompleted: Bool) async throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(AgentResponsesTests().done)
        if !fromCompleted {
            for event in ["response.output_item.added", "response.output_item.done"] {
                _ = try accumulator.consume(JSONValue.object([
                    "type": .string(event), "output_index": .number(0), "item": reasoning
                ]).encodedString())
            }
        }
        let output: [JSONValue] = fromCompleted ? [reasoning, .object([
            "type": .string("function_call"), "call_id": .string("call-1"),
            "name": .string("search"), "arguments": .string("{}")
        ])] : []
        _ = try accumulator.consume(JSONValue.object([
            "type": .string("response.completed"), "response": fromCompleted ? .object(["output": .array(output)]) : .object([:])
        ]).encodedString())
        let response = try accumulator.response()
        #expect(response.providerMetadata == metadata)
        let model = ScriptedAgentModel([response, AgentTurnResponse(text: "Answer")])
        let tool = AgentTool(spec: AgentToolSpec(name: "search", description: "Search", inputSchema: .object([:]))) { _ in
            AgentToolOutput(content: "Found Alice", summary: "Found Alice")
        }
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: [tool]))
        let requests = await model.requests
        let replay = AgentWireFormat.openAIResponses.requestBody(requests[1], model: "gpt-test")
        #expect(replay["include"] == .array([.string("reasoning.encrypted_content")]))
        #expect(replay["input"].array[1] == reasoning)
        #expect(replay["input"].array[2]["type"] == .string("function_call"))
        #expect(replay["input"].array[2]["call_id"] == .string("call-1"))
        #expect(replay["input"].array[3]["type"] == .string("function_call_output"))
        let persisted = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(outcome.messages))
        #expect(persisted == outcome.messages)
        let canonical = try #require(response.message)
        guard case .content(let audited) = persisted[1] else { Issue.record("Expected native assistant"); return }
        #expect(audited.blocks.map(\.content).count == canonical.blocks.count)
        #expect(audited.text == canonical.text && audited.providerMetadata == canonical.providerMetadata)
        #expect(audited.identity?.requestID == requests[0].identity?.id)
        #expect(audited.toolCalls[0].providerMetadata == canonical.toolCalls[0].providerMetadata)
        #expect(audited.toolCalls[0].rawArguments == canonical.toolCalls[0].rawArguments)
        #expect(audited.toolCalls[0].invocationID != nil)
    }

    @Test func metadataFollowsCompactionGroupAndOldMessagesStillDecode() throws {
        let assistant = AgentMessage.assistant(text: "", toolCalls: [agentCall()], providerMetadata: metadata)
        let messages: [AgentMessage] = [.user(String(repeating: "old", count: 1_000)), assistant,
            .toolResult(callID: "1", toolName: "lookup", content: "Found", isError: false), .user("New")]
        let policy = AgentContextPolicy(contextWindow: 1_000, reserveTokens: 0, keepRecentTokens: 13)
        let plan = try #require(AgentContextCompactor(policy: policy).plan(for: messages))
        #expect(plan.isSplitTurn)
        #expect(plan.turnPrefix == [messages[0]])
        #expect(plan.kept == Array(messages.suffix(3)))
        #expect(plan.kept.first == assistant)
        let oldJSON = Data(#"{"assistant":{"text":"Old answer","toolCalls":[]}}"#.utf8)
        #expect(try JSONDecoder().decode(AgentMessage.self, from: oldJSON) == .assistant(text: "Old answer", toolCalls: []))
    }

    @Test(arguments: [AgentWireFormat.anthropic, .openAI, .gemini])
    func otherFormatsIgnoreAssistantMetadata(format: AgentWireFormat) {
        func request(_ metadata: JSONValue?) -> AgentTurnRequest {
            AgentTurnRequest(systemPrompt: "sys", messages: [.assistant(text: "Answer", toolCalls: [agentCall()], providerMetadata: metadata)],
                             tools: [], maxOutputTokens: 10)
        }
        #expect(format.requestBody(request(metadata), model: "test") == format.requestBody(request(nil), model: "test"))
    }

    @Test func functionCallOmitsStaleItemIDWithoutReasoning() {
        let call = AgentToolCall(id: "call-1", name: "search", arguments: .object([:]), rawArguments: "{}",
                                 providerMetadata: .object(["id": .string("stale-item-id")]))
        let request = AgentTurnRequest(systemPrompt: "sys", messages: [.assistant(text: "", toolCalls: [call])],
                                       tools: [], maxOutputTokens: 10)
        let input = AgentWireFormat.openAIResponses.requestBody(request, model: "test")["input"].array
        #expect(input == [.object(["type": .string("function_call"), "call_id": .string("call-1"),
                                  "name": .string("search"), "arguments": .string("{}")])])
    }

    @Test func reasoningPrecedesAssistantTextAndCalls() {
        let request = AgentTurnRequest(systemPrompt: "sys", messages: [
            .assistant(text: "Searching", toolCalls: [agentCall()], providerMetadata: metadata)
        ], tools: [], maxOutputTokens: 10)
        let input = AgentWireFormat.openAIResponses.requestBody(request, model: "test")["input"].array
        #expect(input == [reasoning, .object(["role": .string("assistant"), "content": .string("Searching")]),
            .object(["type": .string("function_call"), "call_id": .string("1"),
                     "name": .string("lookup"), "arguments": .string("{}")])])
    }
}
