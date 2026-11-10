import Foundation
import Testing
@testable import AgentHarness

struct AgentAdaptiveBudgetTests {
    private func tool(scheduling: AgentTool.Scheduling = .sequential) -> AgentTool {
        AgentTool(spec: AgentToolSpec(name: "lookup", description: "Read", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(true)])), scheduling: scheduling) { _ in
            AgentToolOutput(content: "PRIVATE_SOURCE_TEXT", summary: "Read", metrics: [.returnedScalars: 10, .deferredScalars: 20])
        }
    }

    @Test func plannerScalesWithVolumeAndClampsUntrustedCounts() {
        let small = AgentBudgetPlanner.limits(for: AgentWorkload(sourceCount: 13, readableParts: 26, estimatedReadPages: 26))
        let large = AgentBudgetPlanner.limits(for: AgentWorkload(sourceCount: 13, readableParts: 26, estimatedReadPages: 100))
        #expect(small.maxToolCalls == 90)
        #expect(large.maxToolCalls > small.maxToolCalls)
        let capped = AgentBudgetPlanner.limits(for: AgentWorkload(sourceCount: .max, readableParts: .max, estimatedReadPages: .max))
        #expect(capped.maxToolCalls == 192)
        #expect(capped.maxTurns == 48)
        let empty = AgentWorkload(sourceCount: -1, readableParts: -1, estimatedReadPages: -1)
        #expect(empty.metrics.values.allSatisfy { $0 == 0 })
        #expect(AgentLimits(maxTurns: .max, maxToolCalls: .max, continuation: AgentContinuationBudget()).maxToolCalls == 256)
    }

    @Test(arguments: [AgentTool.Scheduling.sequential, .parallelRead])
    func distinctReadsExtendTheBudgetUntilTheHardLimitAndKeepOneLimitRecord(scheduling: AgentTool.Scheduling) async throws {
        let calls = (0..<8).map { agentCall(String($0), raw: "{\"offset\":\($0)}") }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls), AgentTurnResponse(text: "Partial answer")])
        let policy = AgentContinuationBudget(maxTurns: 4, maxToolCalls: 5, turnStep: 2, toolStep: 2)
        let limits = AgentLimits(maxTurns: 2, maxToolCalls: 2, wrapUpOnLimit: true, continuation: policy)
        let events = try await agentEvents(NativeHarness(model: model, limits: limits), tools: [tool(scheduling: scheduling)])
        let trace = events.compactMap { if case .diagnostic(let value) = $0 { return value }; return nil }
        #expect(trace.filter { $0.kind == .budgetExtended }.count == 2)
        #expect(trace.filter { $0.kind == .limitReached }.count == 1)
        #expect(trace.first { $0.kind == .limitReached }?.metrics[.maxToolCalls] == 5)
        #expect(trace.filter { $0.kind == .toolSkipped }.count == 3)
        #expect(trace.filter { $0.kind == .budgetExtensionDenied }.count == 1)
        #expect(try agentOutcome(events).stopReason == .toolCallLimit)
        #expect(!trace.map(\.logLine).joined().contains("PRIVATE_SOURCE_TEXT"))
    }

    @Test(arguments: [AgentTool.Scheduling.sequential, .parallelRead])
    func repeatedReadsAndStaleProgressCannotBuyMoreCalls(scheduling: AgentTool.Scheduling) async throws {
        let policy = AgentContinuationBudget(maxToolCalls: 20)
        for stale in [false, true] {
            let count = stale ? 11 : 4
            let calls = (0..<count).map { agentCall(String($0), raw: "{\"offset\":\(stale && $0 == 0 ? 0 : 1)}") }
            let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls)])
            let limits = AgentLimits(maxToolCalls: stale ? 10 : 2, continuation: policy)
            let events = try await agentEvents(NativeHarness(model: model, limits: limits), tools: [tool(scheduling: scheduling)])
            #expect(!events.contains { if case .diagnostic(let item) = $0 { return item.kind == .budgetExtended }; return false })
            #expect(try agentOutcome(events).stopReason == .toolCallLimit)
        }
    }

    @Test func turnBudgetCanExtendAfterProgress() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1", raw: "{\"offset\":0}")]),
            AgentTurnResponse(text: "", toolCalls: [agentCall("2", raw: "{\"offset\":1}")]), AgentTurnResponse(text: "Done")
        ])
        let limits = AgentLimits(maxTurns: 2, maxToolCalls: 10, continuation: AgentContinuationBudget(maxTurns: 4))
        let events = try await agentEvents(NativeHarness(model: model, limits: limits), tools: [tool()])
        #expect(try agentOutcome(events).stopReason == .completed)
        #expect(events.contains { if case .diagnostic(let item) = $0 { return item.kind == .budgetExtended && item.stopReason == .turnLimit }; return false })
    }

    @Test func costCapStillStopsTheRunAfterAnExtension() async throws {
        let turns = (0..<3).map { index in
            AgentTurnResponse(text: "", toolCalls: [agentCall(String(index), raw: "{\"offset\":\(index)}")],
                              usage: AgentUsage(inputTokens: 1))
        }
        let model = ScriptedAgentModel(turns)
        let limits = AgentLimits(maxTurns: 2, maxToolCalls: 10, maxCostUSD: 3, wrapUpOnLimit: true,
                                 continuation: AgentContinuationBudget(maxTurns: 4))
        let events = try await agentEvents(NativeHarness(model: model, limits: limits, costEstimator: { Double($0.inputTokens) }), tools: [tool()])
        #expect(try agentOutcome(events).stopReason == .costLimit)
        #expect(await model.requests.count == 3)
        #expect(events.filter { if case .diagnostic(let item) = $0 { return item.kind == .budgetExtended }; return false }.count == 1)
        #expect(events.filter { if case .diagnostic(let item) = $0 { return item.kind == .toolSkipped }; return false }.count == 1)
    }
}
