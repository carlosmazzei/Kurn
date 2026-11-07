import AgentHarness
import Foundation
import Testing
@testable import KurnCore

struct ChatAgentTimelineTests {
    @Test func emptyStateTextAndRunRestart() {
        var timeline = ChatAgentTimeline()
        #expect(timeline.steps.isEmpty)
        #expect(timeline.usage == AgentUsage())
        timeline.apply(.textDelta("hello"))
        #expect(timeline.steps.isEmpty)
        timeline.apply(.turnStarted(index: 0))
        timeline.apply(.usage(AgentUsage(inputTokens: 5)))
        timeline.apply(.runStarted)
        #expect(timeline.steps.isEmpty)
        #expect(timeline.usage == AgentUsage())
    }

    @Test func toolLifecycleKeepsCanonicalArgumentsAndSummary() throws {
        var timeline = ChatAgentTimeline()
        timeline.apply(.turnStarted(index: 0))
        let arguments = try JSONValue.parse(#"{"z":2,"a":"text"}"#)
        timeline.apply(.toolStarted(callID: "1", name: "search", arguments: arguments))
        #expect(timeline.steps.map(\.kind) == [.turn, .tool])
        #expect(timeline.steps.last?.status == .running)
        #expect(timeline.steps.last?.argumentsSummary == #"{"a":"text","z":2}"#)
        timeline.apply(.toolFinished(callID: "1", name: "search", summary: "3 excerpts", isError: false))
        #expect(timeline.steps.count == 2)
        #expect(timeline.steps[1].callID == "1")
        #expect(timeline.steps[1].toolName == "search")
        #expect(timeline.steps[1].arguments == arguments)
        #expect(timeline.steps[1].status == .finished)
        #expect(timeline.steps[1].outputSummary == "3 excerpts")
        timeline.apply(.turnStarted(index: 1))
        #expect(timeline.steps[0].status == .finished)
        #expect(timeline.steps.last?.turnIndex == 1)
        let restored = try JSONDecoder().decode([ChatAgentStep].self, from: JSONEncoder().encode(timeline.steps))
        #expect(restored == timeline.steps)
    }

    @Test func failuresAndUnmatchedFinishesArePreserved() {
        var timeline = ChatAgentTimeline()
        timeline.apply(.toolStarted(callID: "bad", name: "read_wiki", arguments: .null))
        timeline.apply(.toolFinished(callID: "bad", name: "read_wiki", summary: "Not allowed", isError: true))
        #expect(timeline.steps[0].status == .failed)
        #expect(timeline.steps[0].outputSummary == "Not allowed")
        timeline.apply(.toolFinished(callID: "missing", name: "unknown", summary: "No tool", isError: true))
        #expect(timeline.steps[1].status == .failed)
        #expect(timeline.steps[1].toolName == "unknown")
        #expect(timeline.steps[1].argumentsSummary == nil)
        timeline.apply(.toolFinished(callID: "orphan", name: "search", summary: "Done", isError: false))
        #expect(timeline.steps[2].status == .finished)
    }

    @Test func compactionAndIncrementalUsage() {
        var timeline = ChatAgentTimeline()
        timeline.apply(.contextCompacted(beforeTokens: 1000, afterTokens: 200))
        #expect(timeline.steps[0].kind == .compaction)
        #expect(timeline.steps[0].beforeTokens == 1000)
        #expect(timeline.steps[0].afterTokens == 200)
        #expect(timeline.steps[0].status == .finished)
        timeline.apply(.usage(AgentUsage(inputTokens: 100, outputTokens: 10)))
        timeline.apply(.usage(AgentUsage(inputTokens: 200, outputTokens: 20)))
        #expect(timeline.usage == AgentUsage(inputTokens: 300, outputTokens: 30))
    }

    @Test(arguments: [AgentRunStopReason.completed, .turnLimit, .toolCallLimit, .costLimit, .outputLimit])
    func stopsAreStructuredAndFinalUsageIsNotDoubleCounted(reason: AgentRunStopReason) {
        var timeline = ChatAgentTimeline()
        timeline.apply(.turnStarted(index: 0))
        timeline.apply(.usage(AgentUsage(inputTokens: 10, outputTokens: 5)))
        let usage = AgentUsage(inputTokens: 10, outputTokens: 5)
        timeline.apply(.runFinished(AgentRunOutcome(messages: [], finalText: "", stopReason: reason, totalUsage: usage)))
        #expect(timeline.steps.map(\.kind) == [.turn, .stop])
        #expect(timeline.steps.allSatisfy { $0.status == .finished })
        #expect(timeline.steps.last?.stopReason == reason)
        #expect(timeline.usage == usage)
    }
}
