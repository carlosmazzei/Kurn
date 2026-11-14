import Foundation
import Testing
@testable import AgentHarness

/// The model's visible reasoning and its narration beside tool calls, shown in order with the calls.
@Suite struct AgentRunTraceReasoningTests {
    /// A clock the test advances by hand, so a reasoning step's duration is exact.
    private final class Clock: @unchecked Sendable {
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { value }
        func advance(_ seconds: TimeInterval) { value += seconds }
    }

    private func thinking(_ id: String, _ text: String?) -> AgentContentBlock {
        AgentContentBlock(id: id, content: .thinking(text: text, signature: nil, redacted: false))
    }

    private func assistant(_ blocks: [AgentContentBlock]) throws -> AgentContentMessage {
        try AgentContentMessage(id: "reply", timestampMilliseconds: 1, role: .assistant, blocks: blocks)
    }

    @Test func reasoningStreamsIntoATimedStepThatTheFinalMessageCompletes() throws {
        let clock = Clock()
        var trace = AgentRunTrace(now: { clock.now() })
        trace.apply(.turnStarted(index: 0))
        trace.apply(.modelContent(.blockStarted(index: 0, block: thinking("t", ""))))
        trace.apply(.modelContent(.blockDelta(id: "t", delta: .thinking("Looking for "))))
        trace.apply(.modelContent(.blockDelta(id: "t", delta: .thinking("the budget"))))
        let live = try #require(trace.steps.last)
        #expect(live.kind == .thinking && live.status == .running && live.text == "Looking for the budget")

        clock.advance(12)
        // The answer starts: the reasoning ends there.
        trace.apply(.modelContent(.blockStarted(index: 1, block: AgentContentBlock(id: "a", content: .text("")))))
        let closed = try #require(trace.steps.last { $0.kind == .thinking })
        #expect(closed.status == .finished && closed.duration == 12)

        // The finished message replaces the streamed text and adds no second step.
        let message = try assistant([thinking("t", "Looking for the budget meetings."),
                                     AgentContentBlock(id: "a", content: .text("Here it is."))])
        trace.apply(.modelContent(.messageFinished(message)))
        #expect(trace.steps.filter { $0.kind == .thinking }.map(\.text) == ["Looking for the budget meetings."])
    }

    @Test func reasoningSentWholeAndRenamedBlocksAppearOnce() throws {
        var trace = AgentRunTrace()
        // A provider that sends reasoning only in the final message.
        trace.apply(.modelContent(.messageFinished(try assistant([thinking("x", "Whole thought.")]))))
        #expect(trace.steps.map(\.kind) == [.thinking])
        #expect(trace.steps[0].text == "Whole thought." && trace.steps[0].duration == nil)

        // A final message whose block was renamed matches the streamed step in order.
        trace.apply(.turnStarted(index: 1))
        trace.apply(.modelContent(.blockStarted(index: 0, block: thinking("streamed", "Part"))))
        trace.apply(.modelContent(.messageFinished(try assistant([thinking("final", "Part one.")]))))
        #expect(trace.steps.filter { $0.kind == .thinking }.map(\.text) == ["Whole thought.", "Part one."])
    }

    @Test func theFinishedMessageCanEmptyOrDropStreamedReasoning() throws {
        var trace = AgentRunTrace()
        trace.apply(.modelContent(.blockStarted(index: 0, block: thinking("t", "First guess"))))
        trace.apply(.modelContent(.messageFinished(try assistant([thinking("t", "")]))))
        // Emptied: the step stays, with no text to reveal.
        #expect(trace.steps.map(\.kind) == [.thinking] && trace.steps[0].text == "")

        trace.apply(.turnStarted(index: 1))
        trace.apply(.modelContent(.blockStarted(index: 0, block: thinking("u", "Draft"))))
        trace.apply(.modelContent(.blockStarted(index: 1, block: thinking("v", "Second draft"))))
        let answer = try assistant([AgentContentBlock(id: "a", content: .text("Answer."))])
        trace.apply(.modelContent(.messageFinished(answer)))
        // Dropped: neither streamed draft remains.
        #expect(trace.steps.filter { $0.kind == .thinking }.count == 1)
        #expect(!trace.steps.contains { $0.text == "Draft" || $0.text == "Second draft" })
    }

    @Test func narrationBesideToolCallsIsShownAndTheAnswerIsNot() throws {
        var trace = AgentRunTrace()
        let call = AgentToolCall(id: "c1", name: "search", arguments: .object([:]), rawArguments: "{}")
        let narrated = try assistant([AgentContentBlock(id: "n", content: .text("I'll search the budget meetings.")),
                                      AgentContentBlock(id: "c", content: .toolCall(call, complete: true))])
        trace.apply(.messageAppended(.content(narrated)))
        trace.apply(.toolStarted(callID: "c1", name: "search", arguments: .object([:])))
        let answer = try AgentContentMessage(id: "answer", timestampMilliseconds: 2, role: .assistant,
                                             blocks: [AgentContentBlock(id: "a", content: .text("The budget is 10."))])
        trace.apply(.messageAppended(.content(answer)))
        #expect(trace.steps.map(\.kind) == [.narration, .tool])
        #expect(trace.steps[0].text == "I'll search the budget meetings.")
    }

    @Test func longReasoningIsBoundedAndStepsStillDecode() throws {
        var trace = AgentRunTrace()
        trace.apply(.modelContent(.blockStarted(index: 0, block: thinking("t", ""))))
        let chunk = String(repeating: "a", count: 1_000)
        for _ in 0..<10 { trace.apply(.modelContent(.blockDelta(id: "t", delta: .thinking(chunk)))) }
        trace.apply(.runFinished(AgentRunOutcome(messages: [], finalText: "", stopReason: .completed, totalUsage: AgentUsage())))
        let text = try #require(trace.steps.first?.text)
        #expect(text.unicodeScalars.count == AgentRunTrace.maxStepTextScalars + 1 && text.hasSuffix("…"))
        #expect(trace.steps.first?.status == .finished)

        let decoded = try JSONDecoder().decode([AgentRunStep].self, from: JSONEncoder().encode(trace.steps))
        #expect(decoded == trace.steps)
        // A step written before these fields existed still reads, with none of them.
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"tool","status":"finished"}"#
        let old = try JSONDecoder().decode(AgentRunStep.self, from: Data(legacy.utf8))
        #expect(old.text == nil && old.duration == nil)
    }

    @Test func aRestoredRunShowsItsCommittedReasoningAndNarration() throws {
        let call = AgentToolCall(id: "c1", name: "search", arguments: .object([:]), rawArguments: "{}")
        let message = try AgentContentMessage(id: "m", timestampMilliseconds: 1, role: .assistant, blocks: [
            thinking("t", "Which meetings mention it?"),
            AgentContentBlock(id: "n", content: .text("Searching.")),
            AgentContentBlock(id: "c", content: .toolCall(call, complete: true))
        ])
        let entry = try AgentSessionEntry(sessionID: "s", id: "e1", parentID: nil, ordinal: 1, createdAt: AgentSessionEntry.time(),
                                          payload: .message(.content(message)), metadata: .object(["runID": .string("run")]))
        let restored = try #require(AgentRunTrace.restoring(run: "run", from: [entry]))
        #expect(restored.steps.map(\.kind) == [.turn, .thinking, .narration, .tool])
        #expect(restored.steps[1].text == "Which meetings mention it?" && restored.steps[1].duration == nil)
    }
}
