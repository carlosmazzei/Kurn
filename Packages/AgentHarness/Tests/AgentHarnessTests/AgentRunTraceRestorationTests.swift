import Foundation
import Testing
@testable import AgentHarness

/// A run's trace rebuilt from the canonical entries `AgentSession` wrote, as a reopened
/// conversation would read them after the process that ran it is gone.
@Suite struct AgentRunTraceRestorationTests {
    /// Runs one tool call and an answer through a branch-mode owner, returning the run's ID and
    /// every entry in the store.
    private func recordedRun() async throws -> (runID: String, entries: [AgentSessionEntry]) {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("call-1")], usage: AgentUsage(inputTokens: 10, outputTokens: 2)),
            AgentTurnResponse(text: "Answer", usage: AgentUsage(inputTokens: 20, outputTokens: 5))
        ])
        let runID = try await session.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [],
                                             prompt: "Q", tools: [agentTool()])
        #expect(await session.waitUntilSettled().end == .completed)
        return (runID.uuidString, await store.entries)
    }

    @Test func aCompletedRunRestoresItsTurnsToolsUsageAndStop() async throws {
        let (runID, entries) = try await recordedRun()
        let trace = try #require(AgentRunTrace.restoring(run: runID, from: entries))

        #expect(trace.steps.map(\.kind) == [.turn, .tool, .turn, .stop])
        #expect(trace.steps.allSatisfy { $0.status == .finished })
        let tool = try #require(trace.steps.first { $0.kind == .tool })
        #expect(tool.callID == "call-1")
        #expect(tool.toolName == "lookup")
        // The live summary is an event, never committed; restoration does not invent one.
        #expect(tool.outputSummary == nil)
        #expect(trace.steps.map(\.turnIndex).compactMap { $0 } == [0, 1])
        #expect(trace.steps.last?.stopReason == .completed)
        #expect(trace.hasUsage)
        #expect(trace.usage == AgentUsage(inputTokens: 30, outputTokens: 7))
    }

    @Test func aRunCutOffMidToolEndsWithTheCallFailedAndNoStop() async throws {
        let (runID, entries) = try await recordedRun()
        // The process died after the assistant asked for the tool and before its result was saved.
        let cut = try #require(entries.firstIndex { if case .message(.tool) = $0.payload { return true }; return false })
        let trace = try #require(AgentRunTrace.restoring(run: runID, from: Array(entries[..<cut])))

        #expect(trace.steps.map(\.kind) == [.turn, .tool])
        #expect(trace.steps.first?.status == .finished)
        #expect(trace.steps.last?.status == .failed)
        #expect(!trace.steps.contains { $0.status == .running })
        #expect(trace.usage == AgentUsage(inputTokens: 10, outputTokens: 2))
    }

    @Test func restoredUsageKeepsItsCacheCounts() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let usage = AgentUsage(inputTokens: 900, outputTokens: 20, cacheReadTokens: 700, cacheWriteTokens: 100)
        let runID = try await session.prompt(harness: NativeHarness(model: ScriptedAgentModel([
            AgentTurnResponse(text: "Answer", usage: usage)
        ])), systemPrompt: "", history: [], prompt: "Q", tools: [])
        _ = await session.waitUntilSettled()
        let trace = try #require(AgentRunTrace.restoring(run: runID.uuidString, from: await store.entries))
        #expect(trace.usage == usage)
    }

    /// Each usage entry names its request; the same request recorded twice counts once, while an
    /// entry from before requests were named still counts.
    @Test func aRequestsUsageCountsOnce() async throws {
        let (runID, entries) = try await recordedRun()
        let usages = entries.filter { $0.kind == "agent.usage.v1" }
        #expect(usages.count == 2)
        for entry in usages {
            guard case .custom(_, .object(let fields)) = entry.payload, case .string(let id)? = fields["requestID"] else {
                Issue.record("A usage entry names no request"); continue
            }
            #expect(!id.isEmpty)
        }
        let first = try #require(usages.first)
        let repeated = try AgentSessionEntry(sessionID: first.sessionID, id: "repeat", parentID: entries.last?.id,
            ordinal: (entries.last?.ordinal ?? 0) + 1, createdAt: first.createdAt, payload: first.payload, metadata: first.metadata)
        guard case .custom(let type, .object(var legacy)) = first.payload else { return }
        legacy["requestID"] = nil
        let unnamed = try AgentSessionEntry(sessionID: first.sessionID, id: "legacy", parentID: "repeat",
            ordinal: repeated.ordinal + 1, createdAt: first.createdAt, payload: .custom(type: type, data: .object(legacy)),
            metadata: first.metadata)
        let trace = try #require(AgentRunTrace.restoring(run: runID, from: entries + [repeated]))
        #expect(trace.usage == AgentUsage(inputTokens: 30, outputTokens: 7))
        let withLegacy = try #require(AgentRunTrace.restoring(run: runID, from: entries + [repeated, unnamed]))
        #expect(withLegacy.usage == AgentUsage(inputTokens: 40, outputTokens: 9))
    }

    @Test func onlyTheNamedRunIsRead() async throws {
        let (_, entries) = try await recordedRun()
        #expect(AgentRunTrace.restoring(run: "another-run", from: entries) == nil)
        // The host's own entry belongs to no run.
        #expect(entries.first { $0.id == "question" }?.runID == nil)
        #expect(entries.filter { $0.runID != nil }.count == entries.count - 1)
    }

    @Test func aResultWithoutItsCallStillAppearsAndAnErrorReadsAsFailed() throws {
        let invocation = try AgentToolInvocation(id: "inv", requestID: "req", callID: "orphan", toolName: "lookup")
        let result = try AgentToolResultMessage(id: "result", timestampMilliseconds: nil, invocation: invocation,
            blocks: [AgentContentBlock(id: "text", content: .text("Failed"))], isError: true)
        let entry = try AgentSessionEntry(sessionID: "session", id: "entry", parentID: nil, ordinal: 1,
            createdAt: AgentSessionEntry.time(), payload: .message(.tool(result)),
            metadata: .object(["runID": .string("run")]))
        let trace = try #require(AgentRunTrace.restoring(run: "run", from: [entry]))
        #expect(trace.steps.map(\.kind) == [.tool])
        #expect(trace.steps.first?.status == .failed)
        #expect(trace.steps.first?.callID == "orphan")
        #expect(!trace.hasUsage)
    }
}
