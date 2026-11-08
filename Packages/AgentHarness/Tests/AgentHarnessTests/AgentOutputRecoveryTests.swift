import Foundation
import Testing
@testable import AgentHarness

struct AgentOutputRecoveryTests {
    private let capacity = AgentContextPolicy(contextWindow: 1_050_000, maxOutputTokens: 128_000)

    private func run(_ harness: NativeHarness, tools: [AgentTool] = [], history: [AgentMessage] = [],
                     output: Int? = nil) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in harness.run(systemPrompt: "System", history: history, prompt: "Question",
                                           tools: tools, maxOutputTokens: output) { events.append(event) }
        return events
    }

    @Test func emptyLimitedReplyRetriesWithoutReexecutingCommittedToolsOrAppendingIncompleteCalls() async throws {
        let limited = AgentUsage(inputTokens: 54_879, outputTokens: 32_768, reasoningTokens: 32_700)
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("committed")], usage: AgentUsage(inputTokens: 3_000, outputTokens: 100)),
            AgentTurnResponse(text: "", toolCalls: [agentCall("discarded", raw: "{incomplete")],
                              usage: limited, stopReason: .maxTokens),
            AgentTurnResponse(text: "", toolCalls: [agentCall("after-recovery")], usage: AgentUsage(inputTokens: 54_879, outputTokens: 100)),
            AgentTurnResponse(text: "Done", usage: AgentUsage(inputTokens: 55_000, outputTokens: 10))
        ])
        let events = try await run(NativeHarness(model: model, contextPolicy: capacity), tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.map(\.maxOutputTokens) == [32_768, 32_768, 65_536, 65_536])
        #expect(requests[1].messages == requests[2].messages)
        #expect(events.compactMap { if case .toolStarted(let id, _, _) = $0 { return id }; return nil }
            == ["committed", "after-recovery"])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .completed)
        #expect(outcome.messages.count == 6)
        #expect(outcome.totalUsage == AgentUsage(inputTokens: 167_758, outputTokens: 32_978, reasoningTokens: 32_700))
        let facts = diagnostics(events)
        #expect(!facts.contains { [.compactionStarted, .limitReached].contains($0.kind) })
        #expect(facts.filter { $0.kind == .outputBudgetExtended }.count == 1)
        let interrupted = try #require(facts.first { $0.kind == .requestFinished && $0.stopReason == .outputLimit })
        #expect(interrupted.metrics[.outputTokens] == 32_768)
        #expect(interrupted.metrics[.reasoningTokens] == 32_700)
        #expect(interrupted.metrics[.visibleTextScalars] == 0)
        #expect(interrupted.metrics[.discardedToolCalls] == 1)
        #expect(facts.contains {
            $0.kind == .contextCheck && $0.metrics[.thresholdTokens] == 984_464 && $0.metrics[.contextTokens] == 54_879
        })
        var trace = AgentRunTrace()
        for event in events { trace.apply(event) }
        #expect(trace.usage == outcome.totalUsage)
        #expect(try JSONDecoder().decode([AgentRunStep].self, from: JSONEncoder().encode(trace.steps)) == trace.steps)
    }

    @Test func oneRetryPerRunStillEndsCleanlyWhenTheHigherAllowanceIsExhausted() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", stopReason: .maxTokens),
            AgentTurnResponse(text: "", toolCalls: [agentCall()]),
            AgentTurnResponse(text: "", stopReason: .maxTokens)
        ])
        let events = try await run(NativeHarness(model: model, contextPolicy: capacity), tools: [agentTool()])
        #expect(await model.requests.map(\.maxOutputTokens) == [32_768, 65_536, 65_536])
        #expect(try agentOutcome(events).stopReason == .outputLimit)
        let facts = diagnostics(events)
        #expect(facts.filter { $0.kind == .outputBudgetExtensionDenied }.count == 1)
        #expect(facts.filter { $0.kind == .limitReached }.map(\.stopReason) == [.outputLimit])
        #expect(facts.last?.kind == .runFinished)
    }

    @Test(arguments: ["visible", "fixed", "provider", "unknown", "turn", "cost"])
    func recoveryRespectsVisibilityAndAllBudgets(block: String) async throws {
        let policy = block == "provider" ? AgentContextPolicy(contextWindow: 1_050_000, maxOutputTokens: 8_000)
            : block == "unknown" ? AgentContextPolicy(contextWindow: 1_050_000) : capacity
        let response = AgentTurnResponse(text: block == "visible" ? "Partial" : "",
                                         usage: AgentUsage(inputTokens: 50, outputTokens: 20), stopReason: .maxTokens)
        let model = ScriptedAgentModel([response])
        let limits = AgentLimits(maxTurns: block == "turn" ? 1 : 10, maxCostUSD: block == "cost" ? 0.5 : nil)
        let harness = NativeHarness(model: model, limits: limits, costEstimator: { _ in 0.5 }, contextPolicy: policy)
        let events = try await run(harness, output: block == "fixed" ? 512 : nil)
        #expect(await model.requests.count == 1)
        #expect(try agentOutcome(events).stopReason == .outputLimit)
        #expect(diagnostics(events).contains { $0.kind == .outputBudgetExtensionDenied })
        #expect(!diagnostics(events).contains { $0.kind == .outputBudgetExtended })
        if block == "provider" { #expect(await model.requests.first?.maxOutputTokens == 8_000) }
        if block == "unknown" { #expect(await model.requests.first?.maxOutputTokens == 4_096) }
    }

    @Test func streamedTextPreventsRetryEvenIfTheFinalReplyIsEmpty() async throws {
        struct Model: AgentModel {
            func streamTurn(_ request: AgentTurnRequest,
                            onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.textDelta("Already visible"))
                return AgentTurnResponse(text: "", stopReason: .maxTokens)
            }
        }
        let events = try await run(NativeHarness(model: Model(), contextPolicy: capacity))
        #expect(diagnostics(events).filter { $0.kind == .requestStarted }.count == 1)
        #expect(diagnostics(events).contains { $0.kind == .outputBudgetExtensionDenied && $0.metrics[.streamedText] == 1 })
    }

    @Test func cancellationDuringRecoveryProducesATerminalDiagnostic() async {
        let capture = DiagnosticCapture()
        let model = ResultScriptedAgentModel([.success(AgentTurnResponse(text: "", stopReason: .maxTokens)), .failure(CancellationError())])
        let harness = NativeHarness(model: model, contextPolicy: capacity, diagnosticSink: { capture.record($0) })
        await #expect(throws: CancellationError.self) { try await run(harness) }
        #expect(capture.events.last?.kind == .runCancelled)
        #expect(capture.events.filter { $0.kind == .requestFailed }.count == 1)
    }

    @Test func automaticOutputAlsoFitsSmallContextWindows() async throws {
        let policy = AgentContextPolicy(contextWindow: 8_192, maxOutputTokens: 128_000)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Done")])
        _ = try await run(NativeHarness(model: model, contextPolicy: policy))
        #expect(await model.requests.first?.maxOutputTokens == 2_048)
    }

    @Test func retryClampsToTheActualProviderOutputCapacity() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", stopReason: .maxTokens), AgentTurnResponse(text: "Done")])
        let policy = AgentContextPolicy(contextWindow: 1_050_000, maxOutputTokens: 50_000)
        _ = try await run(NativeHarness(model: model, contextPolicy: policy))
        #expect(await model.requests.map(\.maxOutputTokens) == [32_768, 50_000])
    }

    @Test func wrapUpCanRecoverWithoutReenablingToolsOrLosingTheFirstLimit() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1"), agentCall("2")]),
            AgentTurnResponse(text: "", stopReason: .maxTokens),
            AgentTurnResponse(text: "Partial conclusion", toolCalls: [agentCall("ignored")])
        ])
        let harness = NativeHarness(model: model, limits: AgentLimits(maxToolCalls: 1, wrapUpOnLimit: true), contextPolicy: capacity)
        let events = try await run(harness, tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.map(\.maxOutputTokens) == [32_768, 32_768, 65_536])
        #expect(!requests[1].allowsToolCalls && !requests[2].allowsToolCalls)
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .toolCallLimit)
        #expect(outcome.finalText == "Partial conclusion")
        #expect(outcome.messages.last == .assistant(text: "Partial conclusion", toolCalls: []))
        #expect(diagnostics(events).filter { $0.kind == .limitReached }.map(\.stopReason) == [.toolCallLimit])
    }

    @Test func compactionFailureBeforeALargerRetryDoesNotMislabelTheCompletedRequest() async {
        let capture = DiagnosticCapture()
        let model = ResultScriptedAgentModel([
            .success(AgentTurnResponse(text: "", stopReason: .maxTokens)), .failure(ScriptedAgentModel.Failure.provider)
        ])
        let policy = AgentContextPolicy(contextWindow: 200_000, maxOutputTokens: 128_000)
        let harness = NativeHarness(model: model, contextPolicy: policy, tokenEstimator: { $0.count },
                                    diagnosticSink: { capture.record($0) })
        let history: [AgentMessage] = [.user(String(repeating: "a", count: 80_000)),
                                       .assistant(text: String(repeating: "b", count: 80_000), toolCalls: [])]
        await #expect(throws: ScriptedAgentModel.Failure.provider) { try await run(harness, history: history) }
        #expect(capture.events.filter { $0.kind == .requestFinished }.count == 1)
        #expect(!capture.events.contains { $0.kind == .requestFailed })
        #expect(capture.events.contains { $0.kind == .summaryFailed })
        #expect(capture.events.contains { $0.kind == .compactionFailed })
        #expect(capture.events.last?.kind == .runFailed)
    }

    private func diagnostics(_ events: [AgentEvent]) -> [AgentDiagnostic] {
        events.compactMap { if case .diagnostic(let value) = $0 { return value }; return nil }
    }
}
