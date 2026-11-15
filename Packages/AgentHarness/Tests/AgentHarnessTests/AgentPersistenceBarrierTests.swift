import Foundation
import Testing
@testable import AgentHarness

actor BarrierProbe {
    enum Failure: Error { case disk }
    var messages: [AgentMessage] = []
    var failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func append(_ message: AgentMessage) throws {
        if messages.count == failAt { throw Failure.disk }
        messages.append(message)
    }
    func count() -> Int { messages.count }
}

@Suite struct AgentPersistenceBarrierTests {
    @Test func userAssistantAndResultCommitsPrecedeDependentWork() async throws {
        let probe = BarrierProbe()
        actor Model: AgentModel {
            let probe: BarrierProbe
            var turns = 0
            init(_ probe: BarrierProbe) { self.probe = probe }
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                #expect(await probe.count() == (turns == 0 ? 1 : 3))
                turns += 1
                return turns == 1 ? AgentTurnResponse(text: "", toolCalls: [agentCall()]) : AgentTurnResponse(text: "Done")
            }
        }
        let tool = AgentTool(spec: agentTool().spec) { _ in
            #expect(await probe.count() == 2)
            return AgentToolOutput(content: "Result", summary: "Result")
        }
        let harness = NativeHarness(model: Model(probe)).persistingMessages { try await probe.append($0) }
        let result = try await harness.start(systemPrompt: "", history: [], prompt: "Question", tools: [tool]).result()
        #expect(result.finalText == "Done")
        #expect(await probe.count() == 4)
    }

    @Test(arguments: [0, 1, 2]) func failedCommitStopsDownstreamWork(at index: Int) async throws {
        let probe = BarrierProbe(failAt: index)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Must not run")])
        actor Counter {
            var calls = 0
            func run() -> AgentToolOutput { calls += 1; return AgentToolOutput(content: "Done", summary: "Done") }
        }
        let counter = Counter()
        let tool = AgentTool(spec: agentTool().spec) { _ in await counter.run() }
        let harness = NativeHarness(model: model).persistingMessages { try await probe.append($0) }
        await #expect(throws: BarrierProbe.Failure.disk) {
            try await harness.start(systemPrompt: "", history: [], prompt: "Q", tools: [tool]).result()
        }
        #expect(await model.requests.count == (index == 0 ? 0 : 1))
        #expect(await counter.calls == (index == 2 ? 1 : 0))
        #expect(await probe.count() == index)
    }

    @Test func blockedCallsAndProviderFailureAuditAreCommitted() async throws {
        let probe = BarrierProbe()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Partial", toolCalls: [agentCall()], stopReason: .maxTokens)])
        let harness = NativeHarness(model: model).persistingMessages { try await probe.append($0) }
        let outcome = try await harness.start(systemPrompt: "", history: [], prompt: "Q", tools: [agentTool()]).result()
        #expect(outcome.stopReason == .outputLimit)
        #expect(await probe.count() == 3)
        let failing = NativeHarness(model: ScriptedAgentModel([], fails: true)).persistingMessages { try await probe.append($0) }
        await #expect(throws: (any Error).self) {
            try await failing.start(systemPrompt: "", history: [], prompt: "Q", tools: []).result()
        }
        #expect(await probe.count() == 5)
    }

    @Test func failedUsageCommitStopsToolEffects() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()], usage: AgentUsage(inputTokens: 10))])
        let probe = BarrierProbe()
        let tool = AgentTool(spec: agentTool().spec) { _ in
            Issue.record("Tool ran after usage persistence failed")
            return AgentToolOutput(content: "", summary: "")
        }
        let harness = NativeHarness(model: model).persistingMessages { try await probe.append($0) }
            .persistingUsage { _ in throw BarrierProbe.Failure.disk }
        await #expect(throws: BarrierProbe.Failure.disk) {
            try await harness.start(systemPrompt: "", history: [], prompt: "Q", tools: [tool]).result()
        }
        #expect(await probe.count() == 1)
        #expect(await model.requests.count == 1)
    }

    @Test func cancellingVisualObservationDoesNotCancelOwnedExecution() async throws {
        struct Model: AgentModel {
            let gate: SessionTestGate
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                await gate.block()
                try Task.checkCancellation()
                return AgentTurnResponse(text: "Answer")
            }
        }
        let gate = SessionTestGate()
        let handle = NativeHarness(model: Model(gate: gate)).start(systemPrompt: "", history: [], prompt: "Q", tools: [])
        let listener = Task { for try await _ in handle.events { } }
        await gate.waitUntilEntered()
        listener.cancel()
        _ = await listener.result
        await gate.release()
        #expect(try await handle.result().finalText == "Answer")
    }

    @Test func ownedObservationIsBoundedAndMayDetachWithoutCancellingTheProducer() async throws {
        struct Model: AgentModel {
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                for _ in 0..<1_000 { onEvent(.textDelta("x")) }
                return AgentTurnResponse(text: "Final")
            }
        }
        let probe = BarrierProbe()
        let handle = NativeHarness(model: Model()).persistingMessages { try await probe.append($0) }
            .start(systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(try await handle.result().finalText == "Final")
        var count = 0
        for try await _ in handle.events { count += 1 }
        #expect(count <= 128)
        #expect(await probe.count() == 2)
    }
}
