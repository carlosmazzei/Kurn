import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentRunProgressTests {
    private func diagnostic(_ kind: AgentDiagnostic.Kind) -> AgentEvent {
        .diagnostic(AgentDiagnostic(runID: UUID(), sequence: 0, kind: kind))
    }

    @Test func aRunMovesThroughItsPhasesWithItsIdentities() throws {
        var progress = AgentRunProgress()
        #expect(progress.phase == .preparing)
        progress.apply(.runStarted)
        let request = try AgentRequestIdentity(id: "req-1")
        progress.apply(.requestStarted(request))
        progress.apply(.turnStarted(index: 0))
        #expect(progress.phase == .streaming)
        #expect(progress.turnIndex == 0)
        #expect(progress.request == request)

        let invocation = try AgentToolInvocation(id: "inv-1", requestID: "req-1", callID: "call-1", toolName: "lookup")
        progress.apply(.invocationRegistered(invocation))
        progress.apply(.toolStarted(callID: "call-1", name: "lookup", arguments: .null))
        progress.apply(.toolStarted(callID: "call-2", name: "lookup", arguments: .null))
        #expect(progress.phase == .executingTools)
        #expect(progress.activeCallIDs == ["call-1", "call-2"])
        #expect(progress.invocations["call-1"] == invocation)
        progress.apply(.toolFinished(callID: "call-1", name: "lookup", summary: "", isError: false))
        #expect(progress.activeCallIDs == ["call-2"])

        progress.apply(.turnStarted(index: 1))
        #expect(progress.turnIndex == 1)
        #expect(progress.invocations.isEmpty)
        progress.apply(.runFinished(AgentRunOutcome(messages: [], finalText: "Done", stopReason: .completed,
                                                    totalUsage: AgentUsage())))
        #expect(progress.phase == .finished)
        #expect(progress.activeCallIDs.isEmpty)
        // Nothing moves a finished run.
        progress.apply(.turnStarted(index: 2))
        progress.apply(diagnostic(.compactionStarted))
        #expect(progress.phase == .finished)
    }

    @Test func compactionInterruptsAndRestoresThePhase() throws {
        var progress = AgentRunProgress()
        progress.apply(.toolStarted(callID: "call-1", name: "lookup", arguments: .null))
        progress.apply(diagnostic(.compactionStarted))
        #expect(progress.phase == .compacting)
        // A turn starting while compacting is remembered, not shown, until compaction ends.
        progress.apply(.turnStarted(index: 3))
        #expect(progress.phase == .compacting)
        progress.apply(diagnostic(.compactionFinished))
        #expect(progress.phase == .streaming)
        #expect(progress.turnIndex == 3)

        progress.apply(diagnostic(.compactionStarted))
        progress.apply(diagnostic(.compactionSkipped))
        #expect(progress.phase == .streaming)
        progress.apply(diagnostic(.compactionStarted))
        progress.apply(diagnostic(.compactionFailed))
        #expect(progress.phase == .streaming)
    }

    @Test func anOutputRetryWaitsUntilItsRequestStarts() throws {
        var progress = AgentRunProgress()
        progress.apply(.turnStarted(index: 0))
        progress.apply(diagnostic(.outputRetryStarted))
        #expect(progress.phase == .retryWaiting)
        progress.apply(.requestStarted(try AgentRequestIdentity(id: "req-2")))
        #expect(progress.phase == .streaming)
        #expect(progress.request?.id == "req-2")
        // An unrelated diagnostic changes nothing.
        progress.apply(diagnostic(.requestFinished))
        #expect(progress.phase == .streaming)
    }

    @Test func aHarnessRunReportsEveryPhaseItPassesThrough() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("call-1")]),
            AgentTurnResponse(text: "Answer")
        ])
        var progress = AgentRunProgress()
        var phases: [AgentRunProgress.Phase] = []
        for event in try await agentEvents(NativeHarness(model: model), tools: [agentTool()]) {
            progress.apply(event)
            if phases.last != progress.phase { phases.append(progress.phase) }
        }
        #expect(phases.first == .preparing || phases.first == .streaming)
        #expect(phases.contains(.executingTools))
        #expect(phases.last == .finished)
        #expect(progress.turnIndex == 1)
    }

    @Test func theRetryWaitLastsAcrossItsTurnAndCompactionUntilItsRequest() throws {
        var progress = AgentRunProgress()
        progress.apply(.turnStarted(index: 0))
        progress.apply(diagnostic(.outputRetryStarted))
        progress.apply(diagnostic(.compactionStarted))
        #expect(progress.phase == .compacting)
        progress.apply(.turnStarted(index: 1))
        progress.apply(diagnostic(.compactionFinished))
        #expect(progress.phase == .retryWaiting)
        progress.apply(.turnStarted(index: 1))
        #expect(progress.phase == .retryWaiting)
        #expect(progress.turnIndex == 1)
        progress.apply(.requestStarted(try AgentRequestIdentity(id: "req-3")))
        #expect(progress.phase == .streaming)
    }

    @Test func finishingAFailedRunLeavesNoCallActive() {
        var progress = AgentRunProgress()
        progress.apply(.toolStarted(callID: "call-1", name: "lookup", arguments: .null))
        progress.apply(diagnostic(.compactionStarted))
        progress.finish()
        #expect(progress.phase == .finished)
        #expect(progress.activeCallIDs.isEmpty)
        progress.apply(diagnostic(.compactionFinished))
        #expect(progress.phase == .finished)
    }
}
