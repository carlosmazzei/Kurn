import Foundation

public enum AgentSessionOwnerError: Error, Sendable, Equatable {
    case busy, persistenceBlocked
}

public struct AgentSessionState: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, preparing, running, cancelling, interrupted }
    public enum End: String, Sendable { case completed, failed, cancelled, persistenceFailed }
    public internal(set) var phase: Phase = .idle
    public internal(set) var runID: UUID?
    public internal(set) var end: End?
    public internal(set) var outcome: AgentRunOutcome?
}

/// Initial NH05 ownership boundary. One actor is retained per session by the host. Observation
/// lifetime does not own execution. This does not activate host UI, queues or canonical replay.
/// The caller supplies an authorized history projection until NH06 defines that projection.
public actor AgentSession {
    public let sessionID: String
    private let store: any AgentSessionStore
    private var state = AgentSessionState()
    private var task: Task<AgentSessionState, Never>?
    private var handle: AgentRunHandle?
    private var cancellationRequested = false
    private var persistenceFailed = false
    private var pendingTerminal: AgentSessionEntry?
    private var terminalEnd: AgentSessionState.End?

    public init(sessionID: String, store: any AgentSessionStore) throws {
        guard AgentContentMessage.validID(sessionID) else { throw AgentSessionStoreError.invalidEntry }
        self.sessionID = sessionID
        self.store = store
    }

    public func snapshot() -> AgentSessionState { state }

    /// Acceptance reserves the actor before the first await. The run continues after this call
    /// returns, and an observer dropping its reference does not cancel the producer.
    @discardableResult
    public func prompt(harness: NativeHarness, systemPrompt: String, history: [AgentMessage], prompt: String,
                       tools: [AgentTool], maxOutputTokens: Int? = nil,
                       contextResolution: AgentContextResolution? = nil) throws -> UUID {
        guard task == nil else { throw AgentSessionOwnerError.busy }
        guard !persistenceFailed else { throw AgentSessionOwnerError.persistenceBlocked }
        let runID = UUID()
        state = AgentSessionState(phase: .preparing, runID: runID)
        cancellationRequested = false
        task = Task {
            await perform(harness: harness, systemPrompt: systemPrompt, history: history, prompt: prompt,
                          tools: tools, maxOutputTokens: maxOutputTokens, contextResolution: contextResolution, runID: runID)
        }
        return runID
    }

    /// A request only. Busy ownership stays held until producer termination and terminal save.
    public func abort() {
        guard task != nil else { return }
        cancellationRequested = true
        state.phase = .cancelling
        handle?.cancel()
    }

    /// Waits for the producer and required durable writes, even if this waiter is cancelled.
    /// A failed durable write is explicit in the returned state and blocks new prompts.
    public func waitUntilSettled() async -> AgentSessionState {
        if let current = task { return await current.value }
        return state
    }

    /// A failed terminal commit can be retried without restarting inference or tool effects.
    /// Returns after acceptance; `waitUntilSettled` also waits for this persistence attempt.
    public func retrySettlement() throws {
        guard task == nil else { throw AgentSessionOwnerError.busy }
        guard let pendingTerminal else { throw AgentSessionOwnerError.persistenceBlocked }
        state.phase = .preparing
        task = Task { await retryTerminal(pendingTerminal) }
    }

    private func retryTerminal(_ terminal: AgentSessionEntry) async -> AgentSessionState {
        do {
            try await append(terminal)
            pendingTerminal = nil
            persistenceFailed = terminalEnd == .persistenceFailed
            state.end = terminalEnd
        } catch { state.end = .persistenceFailed }
        state.phase = state.end == .completed ? .idle : .interrupted
        task = nil
        return state
    }

    private func perform(harness: NativeHarness, systemPrompt: String, history: [AgentMessage], prompt: String,
                         tools: [AgentTool], maxOutputTokens: Int?, contextResolution: AgentContextResolution?, runID: UUID) async -> AgentSessionState {
        var end = AgentSessionState.End.failed
        var outcome: AgentRunOutcome?
        do {
            try await append(payload: .custom(type: "agent.run-start.v1", data: .object(["runID": .string(runID.uuidString)])))
            if cancellationRequested { throw CancellationError() }
            let owned = harness.persistingMessages { [self] message in
                try await appendMessage(message, runID: runID)
            }.persistingUsage { [self] usage in
                try await appendUsage(usage, runID: runID)
            }
            let run = owned.start(systemPrompt: systemPrompt, history: history, prompt: prompt, tools: tools,
                maxOutputTokens: maxOutputTokens, contextResolution: contextResolution,
                context: try AgentRunContext(sessionID: sessionID, runID: runID))
            handle = run
            state.phase = .running
            outcome = try await run.result()
            end = cancellationRequested ? .cancelled : .completed
        } catch {
            end = error is CancellationError ? .cancelled : .failed
        }
        handle = nil
        if persistenceFailed { end = .persistenceFailed }
        terminalEnd = end
        do {
            let data: JSONValue = .object([
                "runID": .string(runID.uuidString), "end": .string(end.rawValue),
                "stopReason": outcome.map { .string($0.stopReason.rawValue) } ?? .null
            ])
            let terminal = try await entry(payload: .custom(type: "agent.run-end.v1", data: data))
            pendingTerminal = terminal
            try await append(terminal)
            pendingTerminal = nil
        } catch {
            persistenceFailed = true
            end = .persistenceFailed
        }
        state.end = end
        state.outcome = outcome
        state.phase = end == .completed ? .idle : .interrupted
        task = nil
        return state
    }

    private func appendMessage(_ message: AgentMessage, runID: UUID) async throws {
        guard state.runID == runID else { throw AgentSessionStoreError.conflict }
        do { try await append(payload: .message(message)) }
        catch { persistenceFailed = true; throw error }
    }

    private func appendUsage(_ usage: AgentUsage, runID: UUID) async throws {
        guard state.runID == runID else { throw AgentSessionStoreError.conflict }
        do {
            let data: JSONValue = .object([
                "inputTokens": .number(Double(usage.inputTokens)), "outputTokens": .number(Double(usage.outputTokens)),
                "reasoningTokens": usage.reasoningTokens.map { .number(Double($0)) } ?? .null
            ])
            try await append(payload: .custom(type: "agent.usage.v1", data: data))
        } catch { persistenceFailed = true; throw error }
    }

    private func entry(payload: AgentSessionEntry.Payload) async throws -> AgentSessionEntry {
        let snapshot = try await store.load(sessionID: sessionID)
        return try AgentSessionEntry(sessionID: sessionID, id: UUID().uuidString, parentID: snapshot.leafID,
            ordinal: snapshot.entries.count + 1, createdAt: AgentSessionEntry.time(), payload: payload,
            metadata: .object(["runID": state.runID.map { .string($0.uuidString) } ?? .null]))
    }

    private func append(payload: AgentSessionEntry.Payload) async throws {
        try await append(entry(payload: payload))
    }

    private func append(_ entry: AgentSessionEntry) async throws {
        let snapshot = try await store.load(sessionID: sessionID)
        if let existing = snapshot.entries.first(where: { $0.id == entry.id }) {
            guard existing == entry else { throw AgentSessionStoreError.conflict }
            return
        }
        try await store.commit(AgentSessionCommit(sessionID: sessionID, expectedRevision: snapshot.revision,
            entries: [entry], leafID: entry.id))
    }
}
