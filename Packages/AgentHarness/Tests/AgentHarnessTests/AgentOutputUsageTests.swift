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

    @Test(arguments: [AgentWireFormat.anthropic, .openAI, .openAIResponses, .gemini])
    func cachedInputIsCountedOnceInTheInputTotal(format: AgentWireFormat) throws {
        let payloads: [String]
        switch format {
        case .anthropic:
            // Anthropic reports cached input apart from input_tokens; the total includes it once.
            payloads = [
                #"{"type":"message_start","message":{"id":"m","model":"c","usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":800,"cache_creation_input_tokens":50}}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":40}}"#,
                #"{"type":"message_stop"}"#
            ]
        case .openAI:
            payloads = [#"{"usage":{"prompt_tokens":950,"completion_tokens":40,"prompt_tokens_details":{"cached_tokens":800}},"choices":[{"delta":{},"finish_reason":"length"}]}"#]
        case .openAIResponses:
            payloads = [#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":950,"output_tokens":40,"input_tokens_details":{"cached_tokens":800}}}}"#]
        case .gemini:
            payloads = [#"{"usageMetadata":{"promptTokenCount":950,"candidatesTokenCount":40,"cachedContentTokenCount":800},"candidates":[{"finishReason":"MAX_TOKENS"}]}"#]
        }
        let accumulator = AgentWireAccumulator(format: format)
        for payload in payloads { _ = try accumulator.consume(payload) }
        let usage = try #require(try accumulator.response().usage)
        #expect(usage.inputTokens == 950)
        #expect(usage.outputTokens == 40)
        #expect(usage.cacheReadTokens == 800)
        #expect(usage.cacheWriteTokens == (format == .anthropic ? 50 : nil))
    }

    @Test func unreportedCountsStayUnknownWhenUsagesAreAdded() throws {
        let reported = AgentUsage(inputTokens: 10, outputTokens: 2, cacheReadTokens: 4)
        let plain = AgentUsage(inputTokens: 5, outputTokens: 1)
        let total = reported.adding(plain)
        #expect(total == AgentUsage(inputTokens: 15, outputTokens: 3, cacheReadTokens: 4))
        #expect(plain.adding(plain).cacheReadTokens == nil)
        #expect(plain.adding(plain).reasoningTokens == nil)
        // Older payloads without cache fields decode with the counts unknown.
        let legacy = try JSONDecoder().decode(AgentUsage.self, from: Data(#"{"inputTokens":12,"outputTokens":10}"#.utf8))
        #expect(legacy.cacheReadTokens == nil && legacy.cacheWriteTokens == nil)
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
