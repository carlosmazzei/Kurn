import Foundation

public enum AgentSessionOwnerError: Error, Sendable, Equatable {
    case busy, persistenceBlocked
    /// The run's history could not be committed, so the run stopped before any work that
    /// depended on it. The store's own error is not passed on: it may describe storage, not the run.
    case persistenceFailed
    /// A run with the same command ID is already in the session's log, so this one did nothing.
    case duplicateCommand
}

/// An accepted run: its identity and a disposable observation of its events. The stream ends
/// only after the run has settled — the producer terminated and its terminal entry was saved —
/// throwing the run's failure: `AgentSessionOwnerError.persistenceFailed` for any history write
/// that failed, including the terminal entry after an answer (which takes precedence over any
/// other failure), and otherwise `CancellationError` for an abort. Dropping it never cancels the run; `abort()` does.
public struct AgentSessionRun: Sendable {
    public let runID: UUID
    public let events: AsyncThrowingStream<AgentEvent, Error>
}

public struct AgentSessionState: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, preparing, running, cancelling, interrupted }
    public enum End: String, Sendable { case completed, failed, cancelled, persistenceFailed, duplicateCommand }
    public internal(set) var phase: Phase = .idle
    public internal(set) var runID: UUID?
    public internal(set) var end: End?
    public internal(set) var outcome: AgentRunOutcome?
}

/// Where a session's appended entries go relative to the selected leaf.
public enum AgentSessionAppendMode: Sendable, Equatable {
    /// Each appended entry becomes the selected leaf: a linear session.
    case selectLeaf
    /// A run's entries form their own branch from the leaf at run start, and the selected leaf
    /// never moves. A host that keeps its own presentation path on the selected leaf can give a
    /// run's canonical history to the owner without either path disturbing the other. In an
    /// empty session the first entry becomes the leaf, since a non-empty log needs one.
    case branch
}

/// Initial NH05 ownership boundary. One actor is retained per session by the host. Observation
/// lifetime does not own execution. This does not activate host UI, queues or canonical replay.
/// The caller supplies the authorized history; `AgentRunBranch` reads earlier runs back from the log.
public actor AgentSession {
    public let sessionID: String
    private let store: any AgentSessionStore
    private var state = AgentSessionState()
    private var task: Task<AgentSessionState, Never>?
    private var handle: AgentRunHandle?
    private var cancellationRequested = false
    private var persistenceFailed = false
    /// The terminal entry's append identity, fixed once chosen so a retried save recognizes a
    /// commit whose acknowledgement was lost.
    private var pendingTerminalID: String?
    private var terminalPayload: AgentSessionEntry.Payload?
    private var terminalEnd: AgentSessionState.End?
    public let appendMode: AgentSessionAppendMode
    /// The current run's newest entry in `.branch` mode, the parent of its next one.
    private var branchTip: String?
    /// The leaf the current run's branch hangs from, read on its first append and kept across
    /// conflict retries, so a host write racing that append cannot move the run's anchor.
    private var branchAnchor: String??
    /// How many times one append is rebuilt after another writer committed first.
    static let conflictAttempts = 4

    public init(sessionID: String, store: any AgentSessionStore, appendMode: AgentSessionAppendMode = .selectLeaf) throws {
        guard AgentContentMessage.validID(sessionID) else { throw AgentSessionStoreError.invalidEntry }
        self.sessionID = sessionID
        self.store = store
        self.appendMode = appendMode
    }

    public func snapshot() -> AgentSessionState { state }

    /// Acceptance reserves the actor before the first await. The run continues after this call
    /// returns, and an observer dropping its reference does not cancel the producer.
    @discardableResult
    public func prompt(harness: NativeHarness, systemPrompt: String, history: [AgentMessage], prompt: String,
                       tools: [AgentTool], maxOutputTokens: Int? = nil,
                       contextResolution: AgentContextResolution? = nil) throws -> UUID {
        try start(harness: harness, systemPrompt: systemPrompt, history: history, prompt: prompt, tools: tools,
                  maxOutputTokens: maxOutputTokens, contextResolution: contextResolution).runID
    }

    /// `prompt` with the run's events. `runID` lets a host reuse an identity it has already
    /// recorded (its own run record); `startFields` are added to the `agent.run-start.v1` entry,
    /// such as the sources and model the host authorized, and cannot replace its `runID`.
    ///
    /// `commandID` makes the command idempotent across processes: it is written into the run's
    /// start entry, and a run whose command ID is already in the session's log — even one another
    /// writer committed while this append was being built — does nothing at all. Its stream ends
    /// with `AgentSessionOwnerError.duplicateCommand`, no entry is written and no model is called.
    public func start(harness: NativeHarness, systemPrompt: String, history: [AgentMessage], prompt: String,
                      tools: [AgentTool], maxOutputTokens: Int? = nil,
                      contextResolution: AgentContextResolution? = nil, runID: UUID = UUID(),
                      commandID: String? = nil, startFields: [String: JSONValue] = [:],
                      system: AgentSystemPrompt? = nil,
                      observation: AgentRunObservation = .bounded) throws -> AgentSessionRun {
        guard commandID.map(AgentContentMessage.validID) ?? true else { throw AgentSessionStoreError.invalidEntry }
        guard task == nil else { throw AgentSessionOwnerError.busy }
        guard !persistenceFailed else { throw AgentSessionOwnerError.persistenceBlocked }
        state = AgentSessionState(phase: .preparing, runID: runID)
        cancellationRequested = false
        branchTip = nil
        branchAnchor = nil
        let (events, observer) = AsyncThrowingStream<AgentEvent, Error>.makeStream(
            bufferingPolicy: observation == .bounded ? .bufferingNewest(128) : .unbounded)
        let request = RunRequest(harness: harness, systemPrompt: system?.text ?? systemPrompt, system: system,
            history: history, prompt: prompt,
            tools: tools, maxOutputTokens: maxOutputTokens, contextResolution: contextResolution,
            commandID: commandID, startFields: startFields, observation: observation)
        task = Task { await perform(request, runID: runID, observer: observer) }
        return AgentSessionRun(runID: runID, events: events)
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
        guard terminalPayload != nil else { throw AgentSessionOwnerError.persistenceBlocked }
        state.phase = .preparing
        task = Task { await retryTerminal() }
    }

    private func retryTerminal() async -> AgentSessionState {
        do {
            try await commitTerminal()
            persistenceFailed = terminalEnd == .persistenceFailed
            state.end = terminalEnd
        } catch { state.end = .persistenceFailed }
        state.phase = state.end == .completed ? .idle : .interrupted
        task = nil
        return state
    }

    private struct RunRequest: Sendable {
        let harness: NativeHarness
        let systemPrompt: String
        let system: AgentSystemPrompt?
        let history: [AgentMessage]
        let prompt: String
        let tools: [AgentTool]
        let maxOutputTokens: Int?
        let contextResolution: AgentContextResolution?
        let commandID: String?
        let startFields: [String: JSONValue]
        let observation: AgentRunObservation
    }

    private func perform(_ request: RunRequest, runID: UUID,
                         observer: AsyncThrowingStream<AgentEvent, Error>.Continuation) async -> AgentSessionState {
        var end = AgentSessionState.End.failed
        var outcome: AgentRunOutcome?
        var failure: Error?
        var fields = request.startFields
        fields["runID"] = .string(runID.uuidString)
        if let commandID = request.commandID { fields["commandID"] = .string(commandID) }
        var startSaved = true
        let startID = UUID().uuidString
        let tools = request.tools.map(\.spec.name)
        do {
            try await append(id: startID, precondition: { snapshot in
                guard let commandID = request.commandID else { return }
                if snapshot.entries.contains(where: { $0.commandID == commandID }) { throw AgentSessionOwnerError.duplicateCommand }
            }, payload: { snapshot in
                // The loadout and system prompt are recorded relative to the previous run (NH06).
                // Runs before this one; after a lost acknowledgement, only those before its entry.
                let own = snapshot.entries.first { $0.id == startID }
                let earlier = AgentRunBranch.all(in: snapshot.entries.filter { entry in
                    entry.id != startID && own.map { entry.ordinal < $0.ordinal } ?? true
                })
                var fields = fields
                fields["tools"] = try Self.json(AgentToolLoadout(names: tools, previous: earlier.last?.toolLoadout?.names))
                if let system = request.system {
                    if let previous = AgentRunBranch.systemPrompts(of: earlier).compactMap({ $0 }).last {
                        fields["systemPatch"] = try Self.json(previous.patch(to: system))
                    } else {
                        fields["system"] = try Self.json(system)
                    }
                }
                return .custom(type: AgentRunBranch.startType, data: .object(fields))
            })
        } catch AgentSessionOwnerError.duplicateCommand {
            return refuseDuplicate(observer: observer)
        } catch {
            startSaved = false
        }
        do {
            guard startSaved else { throw AgentSessionOwnerError.persistenceFailed }
            if cancellationRequested { throw CancellationError() }
            let owned = request.harness.persistingMessages { [self] message in
                try await appendMessage(message, runID: runID)
            }.persistingUsage { [self] usage in
                try await appendUsage(usage, runID: runID)
            }.persistingCompaction { [self] checkpoint in
                try await appendCompaction(checkpoint, runID: runID)
            }
            let run = owned.start(systemPrompt: request.systemPrompt, history: request.history, prompt: request.prompt,
                tools: request.tools, maxOutputTokens: request.maxOutputTokens, contextResolution: request.contextResolution,
                context: try AgentRunContext(sessionID: sessionID, runID: runID), observation: request.observation)
            handle = run
            state.phase = .running
            // An observer that stopped reading or went away does not hold the run back.
            do { for try await event in run.events { observer.yield(event) } } catch {}
            outcome = try await run.result()
            end = cancellationRequested ? .cancelled : .completed
        } catch {
            failure = error
            end = error is CancellationError ? .cancelled : .failed
        }
        handle = nil
        if persistenceFailed { end = .persistenceFailed }
        terminalEnd = end
        let data: JSONValue = .object([
            "runID": .string(runID.uuidString), "end": .string(end.rawValue),
            "stopReason": outcome.map { .string($0.stopReason.rawValue) } ?? .null
        ])
        terminalPayload = .custom(type: "agent.run-end.v1", data: data)
        do {
            try await commitTerminal()
        } catch {
            persistenceFailed = true
            end = .persistenceFailed
            // The session is now blocked until `retrySettlement`, which the observer must learn
            // even when the run itself answered or failed for another reason.
            failure = AgentSessionOwnerError.persistenceFailed
        }
        state.end = end
        state.outcome = outcome
        state.phase = end == .completed ? .idle : .interrupted
        task = nil
        // An abort reads the same to the observer whether the producer threw or returned early.
        if failure == nil, end == .cancelled { failure = CancellationError() }
        if let failure { observer.finish(throwing: failure) } else { observer.finish() }
        return state
    }

    /// A command already in the log: nothing was written, so there is nothing to close.
    private func refuseDuplicate(observer: AsyncThrowingStream<AgentEvent, Error>.Continuation) -> AgentSessionState {
        state.end = .duplicateCommand
        state.phase = .idle
        task = nil
        observer.finish(throwing: AgentSessionOwnerError.duplicateCommand)
        return state
    }

    private func commitTerminal() async throws {
        guard let terminalPayload else { throw AgentSessionOwnerError.persistenceBlocked }
        let id = pendingTerminalID ?? UUID().uuidString
        pendingTerminalID = id
        try await append(payload: terminalPayload, id: id)
        pendingTerminalID = nil
        self.terminalPayload = nil
    }

    private func appendMessage(_ message: AgentMessage, runID: UUID) async throws {
        guard state.runID == runID else { throw AgentSessionStoreError.conflict }
        do { try await append(payload: .message(message)) }
        catch { persistenceFailed = true; throw AgentSessionOwnerError.persistenceFailed }
    }

    private func appendUsage(_ usage: AgentUsage, runID: UUID) async throws {
        guard state.runID == runID else { throw AgentSessionStoreError.conflict }
        do {
            let data: JSONValue = .object([
                "inputTokens": .number(Double(usage.inputTokens)), "outputTokens": .number(Double(usage.outputTokens)),
                "reasoningTokens": usage.reasoningTokens.map { .number(Double($0)) } ?? .null,
                "cacheReadTokens": usage.cacheReadTokens.map { .number(Double($0)) } ?? .null,
                "cacheWriteTokens": usage.cacheWriteTokens.map { .number(Double($0)) } ?? .null
            ])
            try await append(payload: .custom(type: "agent.usage.v1", data: data))
        } catch { persistenceFailed = true; throw AgentSessionOwnerError.persistenceFailed }
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func appendCompaction(_ checkpoint: AgentCompactionCheckpoint, runID: UUID) async throws {
        guard state.runID == runID else { throw AgentSessionStoreError.conflict }
        do {
            let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(checkpoint))
            try await append(payload: .custom(type: AgentCompactionCheckpoint.entryType, data: data))
        } catch { persistenceFailed = true; throw AgentSessionOwnerError.persistenceFailed }
    }

    /// Builds the entry against the snapshot it commits on, so its parent and ordinal are never
    /// stale. Another writer committing in between is a conflict: the entry is rebuilt on the new
    /// snapshot and tried again, a bounded number of times. A failed commit writes nothing, so a
    /// retry cannot duplicate an entry; an `id` already present with the same payload is a commit
    /// whose acknowledgement was lost.
    /// `precondition` sees every snapshot an attempt is built on, so a check it makes (such as a
    /// command already in the log) also holds against a writer that committed in between.
    private func append(payload: AgentSessionEntry.Payload, id: String = UUID().uuidString,
                        precondition: (AgentSessionSnapshot) throws -> Void = { _ in }) async throws {
        try await append(id: id, precondition: precondition, payload: { _ in payload })
    }

    /// `append` with a payload built from the snapshot the attempt commits on (a run start records
    /// what changed since the previous run). The own-entry check compares against the payload
    /// built from that same snapshot, so a lost acknowledgement is still recognized.
    private func append(id: String, precondition: (AgentSessionSnapshot) throws -> Void,
                        payload build: (AgentSessionSnapshot) throws -> AgentSessionEntry.Payload) async throws {
        var attempt = 0
        while true {
            attempt += 1
            let snapshot = try await store.load(sessionID: sessionID)
            let payload = try build(snapshot)
            // This append's own entry first: a commit whose acknowledgement was lost is not a
            // duplicate of itself, whatever the precondition would say about it.
            if let existing = snapshot.entries.first(where: { $0.id == id }) {
                guard existing.payload == payload else { throw AgentSessionStoreError.conflict }
                if appendMode == .branch { branchTip = id }
                return
            }
            try precondition(snapshot)
            if branchAnchor == nil { branchAnchor = .some(snapshot.leafID) }
            let parent = appendMode == .branch ? (branchTip ?? branchAnchor ?? snapshot.leafID) : snapshot.leafID
            let entry = try AgentSessionEntry(sessionID: sessionID, id: id, parentID: parent,
                ordinal: snapshot.entries.count + 1, createdAt: AgentSessionEntry.time(), payload: payload,
                metadata: .object(["runID": state.runID.map { .string($0.uuidString) } ?? .null]))
            do {
                try await store.commit(AgentSessionCommit(sessionID: sessionID, expectedRevision: snapshot.revision,
                    entries: [entry], leafID: appendMode == .branch ? (snapshot.leafID ?? entry.id) : entry.id))
            } catch AgentSessionStoreError.conflict where attempt < Self.conflictAttempts {
                continue
            }
            if appendMode == .branch { branchTip = id }
            return
        }
    }
}
