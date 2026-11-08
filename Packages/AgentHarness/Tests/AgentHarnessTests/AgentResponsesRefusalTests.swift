import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentResponsesRefusalTests {
    let completed = #"""
        {"type":"response.completed","response":{"output":[{"type":"message","content":[
        {"type":"refusal","refusal":"I cannot help with that."}]}],"usage":{"input_tokens":10,"output_tokens":5}}}
        """#

    @Test(arguments: ["", "I cannot ", "I cannot help with that."])
    func refusalIsTextWithoutDuplicatingFinalSnapshot(streamed: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        var events: [AgentModelEvent] = []
        let delta = JSONValue.object(["type": .string("response.refusal.delta"), "delta": .string(streamed),
                                      "output_index": .number(0), "content_index": .number(0)])
        events += try accumulator.consume(delta.encodedString())
        events += try accumulator.consume(completed)
        let response = try accumulator.response()
        #expect(response.text == "I cannot help with that.")
        #expect(response.toolCalls.isEmpty)
        #expect(response.stopReason == .endTurn)
        #expect(response.usage == AgentUsage(inputTokens: 10, outputTokens: 5))
        let text = events.map { event in
            switch event { case .textDelta(let text): text; case .outputBudgetAdjusted: "" }
        }.joined()
        #expect(text == response.text)
    }

    @Test func refusalDeltasStillRequireTerminalEvent() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        #expect(try accumulator.consume(#"{"type":"response.refusal.delta","delta":"I cannot "}"#) == [.textDelta("I cannot ")])
        _ = try accumulator.consume(#"{"type":"response.refusal.delta","delta":"help."}"#)
        #expect(throws: AgentWireError.incompleteStream) { try accumulator.response() }
        _ = try accumulator.consume(#"{"type":"response.completed","response":{}}"#)
        #expect(try accumulator.response().text == "I cannot help.")
    }

    @Test func multipleRefusalPartsReconcileIndependently() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(#"{"type":"response.refusal.delta","output_index":1,"content_index":0,"delta":"No."}"#)
        _ = try accumulator.consume(#"""
            {"type":"response.completed","response":{"output":[{"type":"reasoning"},{"type":"message","content":[
            {"type":"refusal","refusal":"No."},{"type":"refusal","refusal":" Sorry."}]}]}}
            """#)
        #expect(try accumulator.response().text == "No. Sorry.")
    }

    @Test func emptyRefusalIsStillEmptyResponse() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(completed.replacingOccurrences(of: "I cannot help with that.", with: ""))
        #expect(throws: AgentWireError.emptyResponse) { try accumulator.response() }
    }

    @Test(arguments: ["", "Hello", "Hello world"])
    func completedTextReconcilesWithoutDuplication(streamed: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        var events = try accumulator.consume(JSONValue.object([
            "type": .string("response.output_text.delta"), "delta": .string(streamed),
            "output_index": .number(1), "content_index": .number(0)
        ]).encodedString())
        events += try accumulator.consume(#"""
            {"type":"response.completed","response":{"output":[{"type":"reasoning"},{"type":"message","content":[
            {"type":"output_text","text":"Hello world"},{"type":"output_text","text":"!"},{"type":"refusal","refusal":" No."}]}]}}
            """#)
        #expect(try accumulator.response().text == "Hello world! No.")
        #expect(events.map { event in
            switch event { case .textDelta(let text): text; case .outputBudgetAdjusted: "" }
        }.joined() == "Hello world! No.")
    }
}
