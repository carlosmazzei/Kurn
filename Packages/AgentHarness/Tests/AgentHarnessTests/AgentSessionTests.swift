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
    var leaf: String?
    var revision = 0
    /// Another writer commits just before the owner's next commit, which then conflicts.
    var interleavedWrites = 0
    var gate: SessionTestGate?
    var failTerminal = false
    var failMessages = false
    var commitThenThrow = false
    var terminalGate: SessionTestGate?
    var failTerminalLoad = false
    func configure(gate: SessionTestGate? = nil, failTerminal: Bool = false, failMessages: Bool = false, commitThenThrow: Bool = false) {
        self.gate = gate; self.failTerminal = failTerminal; self.failMessages = failMessages; self.commitThenThrow = commitThenThrow
    }
    func configureTerminal(gate: SessionTestGate? = nil, failLoad: Bool = false) {
        terminalGate = gate; failTerminalLoad = failLoad
    }
    func load(sessionID: String) async throws -> AgentSessionSnapshot {
        if failTerminalLoad, let last = entries.last, case .message(.content(let value)) = last.payload, value.role == .assistant {
            failTerminalLoad = false
            throw Failure.disk
        }
        return AgentSessionSnapshot(sessionID: sessionID, revision: revision, leafID: leaf, entries: entries)
    }
    func commit(_ group: AgentSessionCommit) async throws {
        if let gate { self.gate = nil; await gate.block() }
        if interleavedWrites > 0 {
            interleavedWrites -= 1
            try appendHostEntry("host-\(interleavedWrites)-\(entries.count)")
        }
        guard group.expectedRevision == revision else { throw AgentSessionStoreError.conflict }
        if failMessages, group.entries.contains(where: { $0.kind == "message" }) { throw Failure.disk }
        let terminal = group.entries.contains { $0.kind == "agent.run-end.v1" }
        if terminal, let terminalGate { self.terminalGate = nil; await terminalGate.block() }
        if terminal, failTerminal { failTerminal = false; throw Failure.disk }
        _ = try AgentEntryGraph(sessionID: sessionID, entries: entries + group.entries, leafID: group.leafID)
        entries += group.entries; leaf = group.leafID; revision += 1
        if terminal, commitThenThrow { commitThenThrow = false; throw Failure.disk }
    }
    func kinds() -> [String] { entries.map(\.kind) }
    /// A host's own entry on the selected path, such as a presentation-state checkpoint.
    func appendHostEntry(_ id: String) throws {
        let entry = try AgentSessionEntry(sessionID: sessionID, id: id, parentID: leaf, ordinal: entries.count + 1,
            createdAt: AgentSessionEntry.time(), payload: .custom(type: "host.state", data: .object([:])))
        entries.append(entry); leaf = id; revision += 1
    }
    func interleave(_ count: Int) { interleavedWrites = count }
    /// Enough racing host writes to exhaust one append's retries, and no more.
    static let conflictsToExhaustOneAppend = AgentSession.conflictAttempts
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

    @Test func terminalPersistenceKeepsTheSessionBusyUntilItsSaveCompletes() async throws {
        let store = SessionTestStore()
        let gate = SessionTestGate()
        await store.configureTerminal(gate: gate)
        let session = try AgentSession(sessionID: "session", store: store)
        let harness = NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "Answer")]))
        try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        await gate.waitUntilEntered()
        #expect(await session.snapshot().end == nil)
        await #expect(throws: AgentSessionOwnerError.busy) {
            try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Other", tools: [])
        }
        await #expect(throws: AgentSessionOwnerError.busy) { try await session.retrySettlement() }
        await gate.release()
        #expect(await session.waitUntilSettled().end == .completed)
        #expect(await store.kinds().last == "agent.run-end.v1")
    }

    @Test func terminalLoadFailureCanBeRetriedWithoutLosingTheTerminalIntent() async throws {
        let store = SessionTestStore()
        await store.configureTerminal(failLoad: true)
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        try await session.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .persistenceFailed)
        try await session.retrySettlement()
        #expect(await session.waitUntilSettled().end == .completed)
        #expect(await model.requests.count == 1)
        #expect(await store.kinds().last == "agent.run-end.v1")
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

    @Test func branchModeChainsTheRunWithoutMovingTheSelectedLeaf() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let harness = NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "Answer")]))
        try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .completed)
        #expect(await store.leaf == "question")
        let run = await store.entries.filter { $0.id != "question" }
        #expect(run.map(\.kind) == ["agent.run-start.v1", "message", "message", "agent.run-end.v1"])
        #expect(run.first?.parentID == "question")
        for (parent, child) in zip(run, run.dropFirst()) { #expect(child.parentID == parent.id) }
    }

    @Test func aConflictingWriterIsRetriedOnTheNewSnapshot() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        // Two host writes land between the owner's load and commit, as a document effect would.
        await store.interleave(2)
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let harness = NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "Answer")]))
        try await session.prompt(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .completed)
        let entries = await store.entries
        // Ordinals stay dense, the host's newest entry stays selected, and the run chain holds.
        #expect(entries.map(\.ordinal) == Array(1...entries.count))
        #expect(await store.leaf?.hasPrefix("host-") == true)
        let run = entries.filter { $0.metadata != nil }
        #expect(run.count == 4)
        // The race did not move the run's anchor off the question it was accepted on.
        #expect(run.first?.parentID == "question")
        for (parent, child) in zip(run, run.dropFirst()) { #expect(child.parentID == parent.id) }
    }

    @Test func aWriterThatKeepsWinningFailsTheRunExplicitly() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        await store.interleave(1_000)
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        try await session.prompt(harness: NativeHarness(model: model), systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .persistenceFailed)
        #expect(await model.requests.isEmpty)
    }

    @Test func startStreamsTheRunAndEndsOnlyOnceItHasSettled() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let runID = UUID()
        let harness = NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "Answer")]))
        let run = try await session.start(harness: harness, systemPrompt: "", history: [], prompt: "Q", tools: [],
            runID: runID, startFields: ["authorization": .string("scope"), "runID": .string("forged")],
            observation: .complete)
        #expect(run.runID == runID)
        var finished = false
        for try await event in run.events { if case .runFinished = event { finished = true } }
        #expect(finished)
        // The stream ended after the terminal entry was saved, not merely when the producer did.
        #expect(await store.kinds().last == "agent.run-end.v1")
        #expect(await session.snapshot().end == .completed)
        let entries = await store.entries
        let start = try #require(entries.first { $0.kind == "agent.run-start.v1" })
        guard case .custom(_, .object(let fields)) = start.payload else { Issue.record("No run-start fields"); return }
        #expect(fields["runID"] == .string(runID.uuidString))
        #expect(fields["authorization"] == .string("scope"))
        #expect(start.metadata == .object(["runID": .string(runID.uuidString)]))
    }

    @Test func aFailedWriteEndsTheObservationWithATypedPersistenceFailure() async throws {
        let store = SessionTestStore()
        await store.configure(failMessages: true)
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        let run = try await session.start(harness: NativeHarness(model: model), systemPrompt: "", history: [],
                                          prompt: "Q", tools: [], observation: .complete)
        await #expect(throws: AgentSessionOwnerError.persistenceFailed) { for try await _ in run.events {} }
        #expect(await session.snapshot().end == .persistenceFailed)
        #expect(await model.requests.isEmpty)
    }

    @Test func aRunStartThatCannotBeSavedFailsWithoutBlockingTheSession() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        // Every attempt at the run-start loses the race; the terminal entry then commits.
        await store.interleave(SessionTestStore.conflictsToExhaustOneAppend)
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        let run = try await session.start(harness: NativeHarness(model: model), systemPrompt: "", history: [],
                                          prompt: "Q", tools: [], observation: .complete)
        await #expect(throws: AgentSessionOwnerError.persistenceFailed) { for try await _ in run.events {} }
        #expect(await session.snapshot().end == .failed)
        #expect(await model.requests.isEmpty)
        // Nothing of the run was written but its end, so a new prompt is accepted.
        let retry = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        try await session.prompt(harness: NativeHarness(model: retry), systemPrompt: "", history: [], prompt: "Q", tools: [])
        #expect(await session.waitUntilSettled().end == .completed)
    }

    @Test func anAbortEndsTheObservationCancelledAfterTheToolSettles() async throws {
        let store = SessionTestStore()
        let gate = SessionTestGate()
        let session = try AgentSession(sessionID: "session", store: store)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()])])
        let tool = AgentTool(spec: agentTool().spec) { _ in
            await gate.block()
            return AgentToolOutput(content: "Done", summary: "Done")
        }
        let run = try await session.start(harness: NativeHarness(model: model), systemPrompt: "", history: [],
                                          prompt: "Q", tools: [tool], observation: .complete)
        await gate.waitUntilEntered()
        await session.abort()
        await gate.release()
        await #expect(throws: CancellationError.self) { for try await _ in run.events {} }
        #expect(await session.snapshot().end == .cancelled)
        #expect(await store.kinds().last == "agent.run-end.v1")
    }
}
