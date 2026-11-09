import Foundation
import Testing
@testable import AgentHarness

struct AgentOutputUsageTests {
    @Test(arguments: [AgentWireFormat.openAI, .openAIResponses, .gemini])
    func reportedReasoningCountsSurviveLimitedEmptyReplies(format: AgentWireFormat) throws {
        let payload: String
        switch format {
        case .openAI:
            payload = #"{"usage":{"prompt_tokens":54879,"completion_tokens":4096,"completion_tokens_details":{"reasoning_tokens":4096}},"choices":[{"delta":{},"finish_reason":"length"}]}"#
        case .openAIResponses:
            payload = #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":54879,"output_tokens":4096,"output_tokens_details":{"reasoning_tokens":4096}}}}"#
        default:
            payload = #"{"usageMetadata":{"promptTokenCount":54879,"candidatesTokenCount":0,"thoughtsTokenCount":4096},"candidates":[{"finishReason":"MAX_TOKENS"}]}"#
        }
        let accumulator = AgentWireAccumulator(format: format)
        _ = try accumulator.consume(payload)
        let response = try accumulator.response()
        #expect(response.usage == AgentUsage(inputTokens: 54_879, outputTokens: 4_096, reasoningTokens: 4_096))
        #expect(response.text.isEmpty)
        #expect(response.diagnosticMetrics[.outputLimited] == 1)
        #expect(response.diagnosticMetrics[.reasoningTokens] == 4_096)
    }

    @Test func unreportedUsageAndLegacyPayloadsKeepReasoningUnknown() throws {
        let legacy = Data(#"{"inputTokens":12,"outputTokens":10}"#.utf8)
        let usage = try JSONDecoder().decode(AgentUsage.self, from: legacy)
        #expect(usage.reasoningTokens == nil)
        let response = AgentTurnResponse(text: "Done", usage: usage)
        #expect(response.diagnosticMetrics[.reasoningTokens] == nil)
        #expect(response.diagnosticMetrics[.usageReported] == 1)
        #expect(AgentTurnResponse(text: "").diagnosticMetrics[.usageReported] == 0)
    }

    @Test func incompleteTerminalEnvelopeCountsCallsEvenWithoutPriorDeltas() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call","call_id":"1","name":"write","arguments":"{"}]}}"#)
        let response = try accumulator.response()
        #expect(response.toolCalls.isEmpty)
        #expect(response.discardedToolCalls == 1)
        #expect(response.diagnosticMetrics[.discardedToolCalls] == 1)
    }
}
