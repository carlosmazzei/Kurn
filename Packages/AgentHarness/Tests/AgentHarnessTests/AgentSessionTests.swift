import Foundation
import Testing
@testable import AgentHarness

actor SessionTestGate {
    private var entered = false
    private var signal: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func block() async {
        entered = true
        for waiter in waiters { waiter.resume() }
        waiters = []
        await withCheckedContinuation { signal = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { signal?.resume(); signal = nil }
}

actor SessionTestStore: AgentSessionStore {
    enum Failure: Error { case disk }
    let sessionID = "session"
    var entries: [AgentSessionEntry] = []
    var revision = 0
    var gate: SessionTestGate?
    var failTerminal = false
    var failMessages = false
    var commitThenThrow = false
    func configure(gate: SessionTestGate? = nil, failTerminal: Bool = false, failMessages: Bool = false, commitThenThrow: Bool = false) {
        self.gate = gate; self.failTerminal = failTerminal; self.failMessages = failMessages; self.commitThenThrow = commitThenThrow
    }
    func load(sessionID: String) async throws -> AgentSessionSnapshot {
        AgentSessionSnapshot(sessionID: sessionID, revision: revision, leafID: entries.last?.id, entries: entries)
    }
    func commit(_ group: AgentSessionCommit) async throws {
        if let gate { self.gate = nil; await gate.block() }
        guard group.expectedRevision == revision else { throw AgentSessionStoreError.conflict }
        if failMessages, group.entries.contains(where: { $0.kind == "message" }) { throw Failure.disk }
        let terminal = group.entries.contains { $0.kind == "agent.run-end.v1" }
        if terminal, failTerminal { failTerminal = false; throw Failure.disk }
        _ = try AgentEntryGraph(sessionID: sessionID, entries: entries + group.entries, leafID: group.leafID)
        entries += group.entries; revision += 1
        if terminal, commitThenThrow { commitThenThrow = false; throw Failure.disk }
    }
    func kinds() -> [String] { entries.map(\.kind) }
}

@Suite struct AgentSessionTests {
    @Test func acceptanceExcludesConcurrentPromptsEvenDuringPreparation() async throws {
        let store = SessionTestStore()
        let gate = SessionTestGate()
        await store.configure(gate: gate)
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        let harness = NativeHarness(model: model)
        let run = try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        await gate.waitUntilEntered()
        #expect(await session.snapshot().runID == run)
        await #expect(throws: AgentSessionOwnerError.busy) {
            try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Other", tools: [])
        }
        await session.abort()
        #expect(await session.snapshot().phase == .cancelling)
        await gate.release()
        let settled = await session.waitUntilSettled()
        #expect(settled.end == .cancelled && settled.phase == .interrupted)
        #expect(await model.requests.isEmpty)
        #expect(await store.kinds() == ["agent.run-start.v1", "agent.run-end.v1"])
    }

    @Test func cancellationWaitsForProviderTerminationAndAuditWrites() async throws {
        struct Model: AgentModel {
            let gate: SessionTestGate
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.textDelta("Partial"))
                await gate.block() // Deliberately ignores cancellation until the provider confirms.
                try Task.checkCancellation()
                return AgentTurnResponse(text: "Late answer")
            }
        }
        let store = SessionTestStore()
        let gate = SessionTestGate()
        let session = try AgentSession(sessionID: "session", store: store)
        let harness = NativeHarness(model: Model(gate: gate))
        try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        await gate.waitUntilEntered()
        await session.abort()
        #expect(await session.snapshot().phase == .cancelling)
        await #expect(throws: AgentSessionOwnerError.busy) {
            try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Other", tools: [])
        }
        await gate.release()
        let settled = await session.waitUntilSettled()
        #expect(settled.end == .cancelled && settled.outcome == nil)
        #expect(await store.kinds().last == "agent.run-end.v1")
        #expect(await store.entries.contains { if case .message(.content(let value)) = $0.payload { return value.stopReason == .aborted }; return false })
    }

    @Test(arguments: [false, true]) func terminalFailureBlocksNewWorkAndRetryDoesNotRepeatInference(committed: Bool) async throws {
        let store = SessionTestStore()
        await store.configure(failTerminal: !committed, commitThenThrow: committed)
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer", usage: AgentUsage(inputTokens: 10, outputTokens: 5))])
        let harness = NativeHarness(model: model)
        try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .persistenceFailed)
        await #expect(throws: AgentSessionOwnerError.persistenceBlocked) {
            try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Other", tools: [])
        }
        try await session.retrySettlement()
        let settled = await session.waitUntilSettled()
        #expect(settled.end == .completed && settled.phase == .idle && settled.outcome?.finalText == "Answer")
        #expect(await model.requests.count == 1)
        #expect(await store.kinds() == ["agent.run-start.v1", "message", "agent.usage.v1", "message", "agent.run-end.v1"])
    }

    @Test func failedMessageSaveStopsModelAndRemainsExplicitlyBlocked() async throws {
        let store = SessionTestStore()
        await store.configure(failMessages: true)
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        try await session.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .persistenceFailed)
        #expect(await model.requests.isEmpty)
        #expect(await store.kinds().last == "agent.run-end.v1")
        await #expect(throws: AgentSessionOwnerError.persistenceBlocked) { try await session.retrySettlement() }
    }

    @Test func cancellationAfterACommittedToolRetainsItsCanonicalSuccess() async throws {
        let store = SessionTestStore()
        let gate = SessionTestGate()
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()])])
        let tool = AgentTool(spec: agentTool().spec) { _ in
            await gate.block()
            // Simulate a tool whose effect committed before cancellation was observed.
            return AgentToolOutput(content: "Committed", summary: "Committed")
        }
        try await session.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [], prompt: "Q", tools: [tool])
        await gate.waitUntilEntered()
        await session.abort()
        await gate.release()
        #expect(await session.waitUntilSettled().end == .cancelled)
        #expect(await model.requests.count == 1)
        #expect(await store.entries.contains { if case .message(.tool(let value)) = $0.payload { return !value.isError && value.text == "Committed" }; return false })
    }

    @Test func reopenDoesNotAutomaticallyExecuteAndPriorCanonicalEntriesRemain() async throws {
        let store = SessionTestStore()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        let owner = try AgentSession(sessionID: "session", store: store)
        try await owner.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await owner.waitUntilSettled().end == .completed)
        let count = await store.entries.count
        let reopened = try AgentSession(sessionID: "session", store: store)
        #expect(await reopened.snapshot().phase == .idle)
        await reopened.abort()
        #expect(await reopened.waitUntilSettled().phase == .idle)
        #expect(await store.entries.count == count)
        #expect(await model.requests.count == 1)
        #expect(throws: AgentSessionStoreError.invalidEntry) { try AgentSession(sessionID: "", store: store) }
    }
}
