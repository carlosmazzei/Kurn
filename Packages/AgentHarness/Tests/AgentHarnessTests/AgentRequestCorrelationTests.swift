import Foundation
import Testing
@testable import AgentHarness

struct AgentRequestCorrelationTests {
    @Test func nextContextCheckAndRunCompletionDoNotInheritThePreviousRequestOrInvocation() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Done")])
        let capture = DiagnosticCapture()
        _ = try await agentEvents(NativeHarness(model: model, diagnosticSink: { capture.record($0) }), tools: [agentTool()])
        let requests = await model.requests
        let ids = requests.compactMap { $0.identity?.id }
        let events = capture.events
        #expect(ids.count == 2 && ids[0] != ids[1])
        let checks = events.filter { $0.kind == .contextCheck }
        #expect(checks.count == 2 && checks.allSatisfy { $0.correlation?.requestID == nil && $0.correlation?.invocationID == nil })
        #expect(events.filter { $0.kind == .requestStarted }.compactMap { $0.correlation?.requestID } == ids)
        #expect(events.filter { $0.kind == .requestFinished }.compactMap { $0.correlation?.requestID } == ids)
        let tools = events.filter { $0.kind == .toolRequested || $0.kind == .toolFinished }
        #expect(tools.count == 2 && tools.allSatisfy { $0.correlation?.requestID == ids[0] && $0.correlation?.invocationID != nil })
        #expect(events.last?.kind == .runFinished && events.last?.correlation?.requestID == nil && events.last?.correlation?.invocationID == nil)
    }

    @Test func compactionDecisionsAreRunScopedAndOnlySummaryEventsCarryTheSummaryRequest() async throws {
        let cjk = String(repeating: "会议", count: 400)
        let history: [AgentMessage] = [.user(cjk), .assistant(text: cjk, toolCalls: [])]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Summary"), AgentTurnResponse(text: "Answer")])
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: model, contextWindow: 1_000, diagnosticSink: { capture.record($0) })
        _ = try await agentEvents(harness, history: history)
        let requests = await model.requests
        #expect(requests.count == 2 && requests[0].identity?.purpose == .summary && requests[1].identity?.purpose == .response)
        let events = capture.events
        let compaction = events.filter { [.contextCheck, .compactionStarted, .compactionFinished].contains($0.kind) }
        #expect(compaction.map(\.kind) == [.contextCheck, .compactionStarted, .compactionFinished])
        #expect(compaction.allSatisfy { $0.correlation?.requestID == nil && $0.correlation?.invocationID == nil })
        let summary = events.filter { $0.kind == .summaryStarted || $0.kind == .summaryFinished }
        #expect(summary.count == 2 && summary.allSatisfy { $0.correlation?.requestID == requests[0].identity?.id })
        #expect(events.filter { $0.kind == .requestStarted || $0.kind == .requestFinished }.allSatisfy { $0.correlation?.requestID == requests[1].identity?.id })
    }

    @Test(arguments: [false, true])
    func failedRequestsCloseTheirScopeBeforeCompactionOrRunFailure(summary: Bool) async throws {
        let model = ScriptedAgentModel([], fails: true)
        let capture = DiagnosticCapture()
        let cjk = String(repeating: "会议", count: 400)
        let history: [AgentMessage] = summary ? [.user(cjk), .assistant(text: cjk, toolCalls: [])] : []
        let harness = NativeHarness(model: model, contextWindow: summary ? 1_000 : 128_000, diagnosticSink: { capture.record($0) })
        await #expect(throws: ScriptedAgentModel.Failure.provider) { try await agentEvents(harness, history: history) }
        let request = try #require(await model.requests.first?.identity)
        let failed = try #require(capture.events.first { $0.kind == (summary ? .summaryFailed : .requestFailed) })
        #expect(failed.correlation?.requestID == request.id)
        #expect(capture.events.filter { $0.kind == .compactionFailed || $0.kind == .runFailed }.allSatisfy { $0.correlation?.requestID == nil })
        #expect(capture.events.last?.kind == .runFailed && capture.events.last?.correlation?.requestID == nil)
    }
}
