import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentRunSnapshotTests {
    /// Narration beside tool calls moves into the trace, so the streamed reply shows only the turn
    /// still being written.
    @Test func narrationLeavesTheStreamedReply() throws {
        var snapshot = AgentRunSnapshot()
        snapshot.apply(.runStarted)
        snapshot.apply(.textDelta("I'll search."))
        let call = AgentToolCall(id: "c1", name: "search", arguments: .object([:]), rawArguments: "{}")
        let narrated = try AgentContentMessage(id: "m1", timestampMilliseconds: 1, role: .assistant, blocks: [
            AgentContentBlock(id: "n", content: .text("I'll search.")),
            AgentContentBlock(id: "c", content: .toolCall(call, complete: true))
        ])
        snapshot.apply(.messageAppended(.content(narrated)))
        #expect(snapshot.exchanges.last?.text == "")
        #expect(snapshot.trace.steps.contains { $0.kind == .narration && $0.text == "I'll search." })
        snapshot.apply(.textDelta("Found it."))
        #expect(snapshot.exchanges.last?.text == "Found it.")
    }

    @Test func aSnapshotReducesTextTraceProgressToolsAndOutcome() {
        var snapshot = AgentRunSnapshot()
        snapshot.apply(.runStarted)
        snapshot.apply(.turnStarted(index: 0))
        snapshot.apply(.textDelta("Mon"))
        snapshot.apply(.textDelta("day"))
        #expect(snapshot.text == "Monday")
        snapshot.apply(.toolStarted(callID: "call-1", name: "lookup", arguments: .null))
        snapshot.apply(.toolFinished(callID: "call-1", name: "lookup", summary: "Found", isError: false))
        snapshot.apply(.toolFinished(callID: "call-2", name: "write", summary: "", isError: true))
        #expect(snapshot.finishedTools.map(\.callID) == ["call-1", "call-2"])
        #expect(snapshot.finishedTools.last?.isError == true)
        #expect(snapshot.progress.phase == .executingTools)
        let outcome = AgentRunOutcome(messages: [], finalText: "Monday.", stopReason: .completed, totalUsage: AgentUsage())
        snapshot.apply(.runFinished(outcome))
        #expect(snapshot.text == "Monday.")
        #expect(snapshot.outcome == outcome)
        #expect(snapshot.progress.phase == .finished)
        #expect(snapshot.trace.steps.last?.stopReason == .completed)
        #expect(snapshot.eventCount == 8)
        // A new run starts from nothing.
        snapshot.apply(.runStarted)
        #expect(snapshot == {
            var fresh = AgentRunSnapshot()
            fresh.apply(.runStarted)
            return fresh
        }())
    }

    @Test func aSlowObserverGetsTheNewestSnapshotAndNeverMissesTheLast() async throws {
        let (events, source) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let snapshots = AgentRunSnapshots.coalescing(events)
        source.yield(.runStarted)
        for index in 0..<200 { source.yield(.textDelta("\(index % 10)")) }
        source.yield(.runFinished(AgentRunOutcome(messages: [], finalText: "Done", stopReason: .completed,
                                                  totalUsage: AgentUsage())))
        source.finish()
        // Nothing reads until the whole run has been produced: the observer sees far fewer
        // snapshots than events, and the last one is the finished run.
        try await Task.sleep(for: .milliseconds(50))
        var seen: [AgentRunSnapshot] = []
        for try await snapshot in snapshots { seen.append(snapshot) }
        #expect(seen.count < 202)
        #expect(seen.last?.text == "Done")
        #expect(seen.last?.eventCount == 202)
    }

    @Test func theRunsFailureEndsTheSnapshotsAfterTheLastOne() async throws {
        struct Failure: Error {}
        let (events, source) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let snapshots = AgentRunSnapshots.coalescing(events)
        source.yield(.runStarted)
        source.yield(.textDelta("Partial"))
        source.finish(throwing: Failure())
        var last: AgentRunSnapshot?
        await #expect(throws: Failure.self) {
            for try await snapshot in snapshots { last = snapshot }
        }
        #expect(last?.text == "Partial")
    }

    @Test func anOwnedRunsEventsCoalesceIntoItsFinishedSnapshot() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("call-1")]),
            AgentTurnResponse(text: "Answer")
        ])
        let handle = NativeHarness(model: model).start(systemPrompt: "", history: [], prompt: "Q", tools: [agentTool()],
                                                       observation: .complete)
        var last: AgentRunSnapshot?
        for try await snapshot in AgentRunSnapshots.coalescing(handle.events) { last = snapshot }
        #expect(last?.text == "Answer")
        #expect(last?.finishedTools.map(\.callID) == ["call-1"])
        #expect(last?.progress.phase == .finished)
        #expect(last?.trace.steps.contains { $0.kind == .tool } == true)
    }
}
