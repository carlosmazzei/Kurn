import Foundation
import Testing
@testable import AgentHarness

struct AgentLateFailureTests {
    static func completedTools(_ format: AgentWireFormat) -> [String] {
        switch format {
        case .openAI:
            return [#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#]
        case .anthropic:
            return [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                #"{"type":"message_stop"}"#
            ]
        case .openAIResponses:
            return [
                #"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call","name":"lookup","arguments":"{}"}}"#,
                #"{"type":"response.completed","response":{}}"#
            ]
        case .gemini:
            return [#"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"call","name":"lookup","args":{}}}]},"finishReason":"STOP"}]}"#]
        }
    }

    @Test(arguments: AgentWireFormat.allCases)
    func errorAfterFinishPoisonsResponseAndCannotBeClearedByTrailingUsage(format: AgentWireFormat) throws {
        let accumulator = AgentWireAccumulator(format: format)
        for payload in Self.completedTools(format) { _ = try accumulator.consume(payload) }
        #expect(try accumulator.response().toolCalls.count == 1)
        #expect(throws: AgentWireError.remote("Late failure")) {
            try accumulator.consume(#"{"error":{"message":"Late failure"}}"#)
        }
        #expect(throws: AgentWireError.remote("Late failure")) { try accumulator.consume(#"{"usage":{"completion_tokens":99}}"#) }
        #expect(throws: AgentWireError.remote("Late failure")) { try accumulator.response() }
    }

    @Test(arguments: [
        #"{"type":"response.failed","response":{"error":{"message":"Late failure"}}}"#,
        #"{"type":"error","message":"Late failure"}"#
    ])
    func responsesTypedFailuresRemainAuthoritativeAfterFinalOutput(payload: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        for item in Self.completedTools(.openAIResponses) { _ = try accumulator.consume(item) }
        #expect(throws: AgentWireError.remote("Late failure")) { try accumulator.consume(payload) }
        #expect(throws: AgentWireError.remote("Late failure")) { try accumulator.response() }
    }

    @Test(arguments: ["garbage", "[]"])
    func malformedOrOversizedTrailersCannotBeSalvagedIntoExecutableCalls(payload: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAI)
        for item in Self.completedTools(.openAI) { _ = try accumulator.consume(item) }
        let expected: AgentWireError = payload.utf8.count > 8 * 1_024 * 1_024 ? .bufferLimit : .invalidResponse
        #expect(throws: expected) { try accumulator.consume(payload) }
        #expect(throws: expected) { try accumulator.response() }
    }

    @Test func oversizedTrailerFailsExplicitlyInsteadOfReturningTools() throws {
        let accumulator = AgentWireAccumulator(format: .openAI)
        for item in Self.completedTools(.openAI) { _ = try accumulator.consume(item) }
        #expect(throws: AgentWireError.bufferLimit) { try accumulator.consume(String(repeating: "x", count: 8 * 1_024 * 1_024 + 1)) }
        #expect(throws: AgentWireError.bufferLimit) { try accumulator.response() }
    }

    @Test(arguments: [
        (AgentWireFormat.anthropic, #"{"type":"error"}"#, AgentWireError.remote("Stream error")),
        (AgentWireFormat.openAIResponses, #"{"type":"error"}"#, AgentWireError.invalidResponse),
        (AgentWireFormat.openAIResponses, #"{"type":"response.failed","response":{}}"#, AgentWireError.invalidResponse)
    ])
    func typedFailuresWithoutMessagesStillInvalidateTheStream(format: AgentWireFormat, payload: String, expected: AgentWireError) throws {
        let accumulator = AgentWireAccumulator(format: format)
        for item in Self.completedTools(format) { _ = try accumulator.consume(item) }
        #expect(throws: expected) { try accumulator.consume(payload) }
        #expect(throws: expected) { try accumulator.response() }
    }

    @Test func completedStreamStillAcceptsUsageAndIgnoresLateContentAndDoneMarkers() throws {
        let accumulator = AgentWireAccumulator(format: .openAI)
        for item in Self.completedTools(.openAI) { _ = try accumulator.consume(item) }
        _ = try accumulator.consume(#"{"usage":{"prompt_tokens":10,"completion_tokens":8}}"#)
        #expect(try accumulator.consume("  [DONE]\n").isEmpty)
        #expect(try accumulator.consume(#"{"choices":[{"delta":{"content":"late private text"}}]}"#).isEmpty)
        let response = try accumulator.response()
        #expect(response.text.isEmpty && response.toolCalls.count == 1)
        #expect(response.usage == AgentUsage(inputTokens: 10, outputTokens: 8))
    }

    @Test(arguments: AgentWireFormat.allCases)
    func harnessNeverExecutesCallsWhenTheTransportReportsAnErrorAfterFinish(format: AgentWireFormat) async throws {
        struct Model: AgentModel {
            let format: AgentWireFormat
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                try await AgentModelBoundary.perform(onEvent: onEvent, prepare: {
                    AgentWireAccumulator(format: format, requestID: request.identity?.id ?? "request")
                }, stream: { accumulator in
                    for payload in AgentLateFailureTests.completedTools(format) + [#"{"error":{"message":"Late failure"}}"#] {
                        for event in try accumulator.consume(payload) { onEvent(event) }
                    }
                    return try accumulator.response()
                })
            }
        }
        let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Tool executed after provider failure"); return AgentToolOutput(content: "", summary: "") }
        var observed: [AgentEvent] = []
        do {
            for try await event in NativeHarness(model: Model(format: format)).run(systemPrompt: "", history: [], prompt: "Question", tools: [tool]) {
                observed.append(event)
            }
            Issue.record("Expected provider failure")
        } catch { #expect(error as? AgentWireError == .remote("Late failure")) }
        #expect(!observed.contains { if case .toolStarted = $0 { return true }; return false })
        #expect(observed.contains(.modelContent(.failed(.transport))))
        let request = try #require(observed.compactMap { if case .requestStarted(let value) = $0 { return value }; return nil }.first)
        let diagnostics = observed.compactMap { if case .diagnostic(let value) = $0 { return value }; return nil }
        #expect(diagnostics.first { $0.kind == .requestFailed }?.correlation?.requestID == request.id)
        #expect(diagnostics.last?.kind == .runFailed && diagnostics.last?.correlation?.requestID == nil)
        #expect(observed.contains { if case .messageAppended(.tool(let result)) = $0 { return result.isError && result.syntheticReason == .interruptedResponse }; return false })
        #expect(!observed.contains { if case .runFinished = $0 { return true }; return false })
    }
}
