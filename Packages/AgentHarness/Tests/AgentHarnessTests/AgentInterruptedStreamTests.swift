import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentInterruptedStreamTests {
    @Test(arguments: AgentWireFormat.allCases, [false, true])
    func missingTerminalEventFails(format: AgentWireFormat, tool: Bool) throws {
        let accumulator = AgentWireAccumulator(format: format)
        let payload: String
        switch format {
        case .anthropic:
            payload = tool
                ? #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"read","input":{}}}"#
                : #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial"}}"#
        case .openAI:
            payload = tool
                ? #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read","arguments":"{}"}}]}}]}"#
                : #"{"choices":[{"delta":{"content":"Partial"}}]}"#
        case .openAIResponses:
            payload = tool
                ? #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"a","name":"read","arguments":"{}"}}"#
                : #"{"type":"response.output_text.delta","delta":"Partial"}"#
        case .gemini:
            payload = tool
                ? #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{}}}]}}]}"#
                : #"{"candidates":[{"content":{"parts":[{"text":"Partial"}]}}]}"#
        }
        _ = try accumulator.consume(payload)
        _ = try accumulator.consume("[DONE]")
        #expect(throws: AgentWireError.incompleteStream) { try accumulator.response() }
    }

    @Test func anthropicMessageStopIsTerminal() throws {
        let accumulator = AgentWireAccumulator(format: .anthropic)
        _ = try accumulator.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Done"}}"#)
        _ = try accumulator.consume(#"{"type":"message_stop"}"#)
        #expect(try accumulator.response().stopReason == .endTurn)
    }
}
