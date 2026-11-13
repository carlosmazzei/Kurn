//
//  MeetingChatViewModel.swift
//  Kurn
//
//  Drives "chat with your meetings": owns the in-memory conversation and runs each
//  question through NativeHarness (`HarnessChatService`) with the selected sources.
//  Chat needs a cloud provider with an `AgentModel`; Apple's on-device model has none.
//
//  A conversation is also the unit of persistence: `configure(meeting:modelContext:)`
//  wires up the `ChatSession` scope (per-meeting or library-wide), and a
//  successfully completed exchange is saved into `session` — created lazily on
//  the first one, so a conversation the user opens and abandons never leaves an
//  empty row in the history list. Document mutations also save the session.
//  A cancelled/failed partial answer is dropped, while its execution trace and
//  reported usage are retained on the retryable question (see `dropPartialReply`).
//
//  NH05: the app retains this object through `ChatConversationHost`, not the view,
//  so a run survives its view being dismissed. A run is an owned `AgentRunHandle`;
//  `cancel()` is a request, and the conversation stays busy (`phase == .cancelling`)
//  until the producer has terminated and the partial reply has been reconciled.
//

import AgentHarness
import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class MeetingChatViewModel {
    private(set) var turns: [Turn] = []
    private(set) var isResponding = false
    /// What the current run is doing; `.idle` exactly when `isResponding` is false.
    private(set) var phase: ChatRunPhase = .idle
    /// The current run's turn, request and tool calls (NH05 phase/identity projection).
    private(set) var runProgress = AgentRunProgress()
    private(set) var scopeEditor = ChatSourceScopeEditor()
    var scope: ChatSourceScope { scopeEditor.scope }
    private(set) var artifacts: [ChatDocumentArtifact] = []
    @ObservationIgnored private var workspace = ChatDocumentWorkspace()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var conversationID = UUID()
    @ObservationIgnored private var retryArtifacts: [ChatArtifactReference] = []
    @ObservationIgnored private var retryOrigins: [UUID: ChatArtifactOrigin] = [:]
    private let agentModelFactory: HarnessChatService.ModelFactory
    private let harnessService: HarnessChatService
    /// The saved conversation backing `turns`, or `nil` for a not-yet-saved
    /// one — set by `configure`, `startNewSession`, or `load(session:)`, and
    /// created lazily by `persist()` on the first successful exchange.
    @ObservationIgnored private var session: ChatSession?
    @ObservationIgnored private var modelContext: ModelContext?
    /// Scopes both retrieval-independent persistence (which `Meeting`, if
    /// any, a new `ChatSession` belongs to) and `pastSessions()`'s filter.
    /// `nil` for the library-wide "Ask".
    @ObservationIgnored private var meeting: Meeting?
    /// `session`'s id, exposed for the history list to highlight the
    /// currently open conversation. `nil` for one not yet saved.
    var currentSessionID: UUID? { session?.id }
    var artifactSession: ChatSession? { session }
    var error: AppError?

    /// The run's owner task. Retained until the run settles, which is what `send` and
    /// `waitUntilSettled` key off. Dismissing a view no longer cancels it (it used to, from
    /// `deinit`, when the view owned this object): the host retains the conversation instead.
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runToken: UUID?
    /// Question turns of the loaded session whose runs were interrupted (`ChatRunRecovery`).
    private var interruptedQuestionIDs: Set<UUID> = []
    /// The session and `ChatRunRecord` of the current run, closed as `.ended` when it settles.
    @ObservationIgnored private var runRecord: (session: ChatSession, record: ChatRunRecord)?
    /// What the current run was asked, kept until it settles so a background wind-down can
    /// hand it to `pendingForegroundResume`.
    @ObservationIgnored private var currentRequest: ForegroundResume?
    /// A question the background wind-down stopped, sent again once on return to the
    /// foreground (`resumeAfterForeground`). A user stop, a new question, `reset` or `load`
    /// clear it: only an interruption the user did not ask for is resumed.
    @ObservationIgnored var pendingForegroundResume: ForegroundResume?
    /// A question a dead process left interrupted, which reopening its conversation resumes once
    /// (`resumeInterruptedRun`, `ChatRunRecovery.resumableInterruptedRun`). Set by `load`;
    /// cleared by `reset`, `send` and the resume itself.
    var interruptedResume: InterruptedResume?
    /// Whether the last stopped run committed a document change before it stopped. A resumed
    /// run would call the tool again under a new invocation identity, which no receipt matches,
    /// so such a question is left for the user to retry instead of being resumed.
    @ObservationIgnored var stoppedRunCommittedEffects = false
    /// The background-execution window held for the current run (see `send`).
    @ObservationIgnored private var backgroundWindow: (any BackgroundExecutionWindow)?
    @ObservationIgnored private let makeBackgroundWindow: @MainActor () -> any BackgroundExecutionWindow
    /// Input queued for the running reply (NH08, `MeetingChatViewModel+Queue`); nil with no run.
    @ObservationIgnored var inputQueue: AgentInputQueue?
    @ObservationIgnored var queueObserver: Task<Void, Never>?
    /// The queued lists shown above the composer.
    var queued = AgentInputQueue.Snapshot()
    /// Text handed back to the composer: queued input a stop or a failed run did not answer.
    var restoredDraft: String?

    /// Tests pass a scripted `AgentModel` through `agentModelFactory`.
    init(agentModelFactory: @escaping HarnessChatService.ModelFactory = { try ProviderFactory.agentModel(for: $0, model: $1) },
         harnessService: HarnessChatService = HarnessChatService(),
         makeBackgroundWindow: @escaping @MainActor () -> any BackgroundExecutionWindow = { BackgroundActivity() }) {
        self.agentModelFactory = agentModelFactory
        self.harnessService = harnessService
        self.makeBackgroundWindow = makeBackgroundWindow
    }

    /// Send `question` to the agent over the current source scope. `provider`/`model` come from
    /// the summary settings. No-op while a previous reply is still in flight. A provider without
    /// an `AgentModel` (Apple's on-device model) fails with the cloud-provider notice; the view
    /// disables the composer for it before that can happen.
    func send(question: String, provider: AIProvider, model: String, runID: OperationID = OperationID(),
              commandID: String? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, task == nil else { return }
        // A named command already in the log is refused before its question is saved, so a repeat
        // leaves the conversation untouched (a concurrent repeat is undone below).
        if let commandID, let session, let modelContext,
           ChatRunBranch.contains(command: commandID, in: session, store: SwiftDataAgentSessionStore(context: modelContext)) {
            error = Self.presentedError(AgentSessionOwnerError.duplicateCommand)
            return
        }
        error = nil
        pendingForegroundResume = nil
        interruptedResume = nil
        stoppedRunCommittedEffects = false

        generation = UUID()
        let generation = self.generation

        turns.append(Turn(role: .user, text: trimmed))
        // The run's durable command identity (NH05): the question turn it answers, unless the
        // caller names one, so the same command is never run twice from the session's log.
        let command = commandID ?? turns[turns.count - 1].id.uuidString
        turns[turns.count - 1].artifacts = retryArtifacts
        turns[turns.count - 1].artifactOrigins = retryOrigins
        retryArtifacts = []
        retryOrigins = [:]
        // Persistence barrier (NH05): the question is saved before any request, so a crash or a
        // suspension mid-run can lose the reply but never the question. A failed save stops here
        // with the question left retryable; nothing is sent that the store has not accepted.
        do { try persistOrThrow() } catch {
            if !(error is CancellationError) {
                self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.invalid", comment: "Saved chat storage error"))
            }
            return
        }
        isResponding = true
        phase = .preparing
        runProgress = AgentRunProgress()
        currentRequest = ForegroundResume(question: trimmed, provider: provider, model: model)
        let token = UUID()
        runToken = token
        beginRunRecord(token, questionTurnID: turns[turns.count - 1].id)
        // Suspension policy (NH05): a run outlives its view, so it can also outlive the
        // foreground. Hold a finite background window for it; when the system reclaims the
        // window, stop the run so it settles as an interruption (retryable question, committed
        // artifacts kept) instead of being frozen mid-request or mid-tool.
        let window = makeBackgroundWindow()
        backgroundWindow = window
        window.begin(name: "ai.kurn.chat") { [weak self] in
            self?.expireInBackground(token, runID: runID)
        }
        let priorTurns = Array(turns.dropLast())
        // A cancel or failure drops whatever reply was appended after the question, so the
        // question stays as the retryable, unanswered turn.
        let turnCountBeforeReply = turns.count
        // `runID` correlates the `ReliabilityEvent` this turn produces; a parameter (defaulted) so
        // a test can pick its own events out of the process-global log.
        let startedAt = Date()

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.settle(token) }
            do {
                try Task.checkCancellation()
                guard let agentModel = try agentModelFactory(provider, model) else {
                    throw AppError.apiError(statusCode: 0, message: NSLocalizedString(
                        "chat.artifact.cloud_required", comment: "Chat provider requirement"))
                }
                let answered = try await self.runHarness(agentModel, runID: token, commandID: command, question: trimmed,
                                                         history: priorTurns,
                                                         provider: provider, model: model, startedAt: startedAt)
                try Task.checkCancellation()
                guard self.generation == generation else { throw CancellationError() }
                self.persist()
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: answered ? .succeeded : .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: answered ? nil : "agent_limit"
                ))
            } catch is CancellationError {
                if self.generation == generation { self.dropPartialReply(keeping: turnCountBeforeReply) }
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
            } catch {
                let appError = Self.presentedError(error)
                if self.generation == generation {
                    self.dropPartialReply(keeping: turnCountBeforeReply)
                    // A repeat that raced past the check above ran nothing: its question goes too.
                    if (error as? AgentSessionOwnerError) == .duplicateCommand, self.turns.last?.role == .user {
                        self.turns.removeLast()
                        self.persist()
                    }
                    self.error = appError
                }
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: ChatRunBranch.isWriteFailure(error) ? "run_transcript_write_failed"
                        : error is AppError ? appError.logCode : "unexpected"
                ))
            }
        }
    }

    /// Ends the run `token` started, whichever conversation is on screen by now: a fenced old
    /// generation cannot change content, but it still owns the busy state until it terminates.
    private func settle(_ token: UUID) {
        guard runToken == token else { return }
        runToken = nil
        task = nil
        currentRequest = nil
        isResponding = false
        phase = .idle
        backgroundWindow?.end()
        backgroundWindow = nil
        markRunRecord(.ended)
    }

    /// Writes the `.running` `ChatRunRecord` for this run into the saved session. Best effort: a
    /// failure is reported, not fatal, since the question itself is already durable.
    private func beginRunRecord(_ token: UUID, questionTurnID: UUID) {
        guard let session, let modelContext else { return }
        let record = ChatRunRecord(runID: token.uuidString, questionTurnID: questionTurnID)
        runRecord = (session, record)
        writeRunRecord(record, in: session, context: modelContext)
    }

    private func markRunRecord(_ state: ChatRunRecord.State) {
        guard let current = runRecord else { return }
        runRecord = nil
        let target = current.session
        guard let modelContext, !target.isDeleted, target.modelContext != nil else { return }
        var updated = current.record
        updated.state = state
        writeRunRecord(updated, in: target, context: modelContext)
    }

    private func writeRunRecord(_ record: ChatRunRecord, in target: ChatSession, context: ModelContext) {
        do {
            try SwiftDataAgentSessionStore(context: context).put(record.record(), in: target,
                                                                 expectedRevision: target.canonicalRevision)
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: OperationID(String(record.runID.prefix(8))), operation: "meeting_chat",
                stage: "run_record", outcome: .failed, code: "run_record_write_failed"
            ))
        }
    }

    /// The background window for run `token` is running out: cancel it like a user stop,
    /// early enough (`BackgroundDeadline`) that settling still runs inside the window. The
    /// system's own expiration may call this again; only the first call acts.
    private func expireInBackground(_ token: UUID, runID: OperationID) {
        guard runToken == token, phase != .cancelling else { return }
        ReliabilityLog.record(ReliabilityEvent(
            operationID: runID, operation: "meeting_chat", stage: "background",
            outcome: .cancelled, code: "background_expired"
        ))
        let request = currentRequest
        cancel()
        pendingForegroundResume = request
    }

    /// Returns once the current run, if any, has terminated and reconciled its reply.
    func waitUntilSettled() async {
        while let task { await task.value }
    }

    // MARK: - Persistence

    /// Saves the whole conversation so far into `session`, creating it (and
    /// deriving its title from the first question) on the first successful
    /// exchange. A cancelled/failed reply never reaches it with its partial turns —
    /// `dropPartialReply` removes those first.
    /// A save failure is logged and surfaced but leaves the conversation on
    /// screen exactly as it is — the user's answer is not lost, only its
    /// persistence.
    private func persist(turns savedTurns: [Turn]? = nil) {
        do { try persistOrThrow(turns: savedTurns) }
        catch is CancellationError {}
        catch { self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.invalid", comment: "Saved chat storage error")) }
    }

    private func persistOrThrow(turns savedTurns: [Turn]? = nil) throws {
        guard let modelContext else { return }
        // A retained conversation can outlive its meeting or saved session: deleting either while
        // a run settles must not write into (or resurrect) a deleted row.
        if let meeting, meeting.isDeleted || meeting.modelContext == nil { throw CancellationError() }
        if let session, session.isDeleted || session.modelContext == nil { throw CancellationError() }
        let target: ChatSession
        if let session {
            target = session
        } else {
            let firstQuestion = turns.first(where: { $0.role == .user })?.text ?? ""
            target = ChatSession(meeting: meeting, title: ChatSession.title(from: firstQuestion))
            target.id = conversationID
            modelContext.insert(target)
            session = target
        }
        try SwiftDataAgentSessionStore(context: modelContext).writePresentation(target,
            turns: (savedTurns ?? turns).map(PersistedChatTurn.init), scope: scope, artifacts: artifacts, preserveCommittedArtifacts: true)
        artifacts = try target.harnessSnapshot().artifacts
    }

    /// Removes any turn appended after `count` — the partial assistant reply
    /// a cancellation or failure leaves behind — so the conversation reads as
    /// "the question is still unanswered" rather than a broken half-answer
    /// sitting next to an error. Leaves the question turn itself untouched.
    private func dropPartialReply(keeping count: Int) {
        guard turns.count > count else { return }
        for turn in turns.dropFirst(count) {
            turns[count - 1].inheritArtifacts(from: turn)
            turns[count - 1].steps = turn.steps
            turns[count - 1].usage = turn.usage
            turns[count - 1].costUSD = turn.costUSD
        }
        turns.removeLast(turns.count - count)
        persist()
    }

    /// The question of the most recent turn when it ended without a reply —
    /// cancelled or failed before (or without) producing an answer — mirroring
    /// the retry affordance Claude/ChatGPT-style chat UIs show under an
    /// interrupted turn. `nil` while a reply is in flight or once the last
    /// turn has a real answer.
    var retryableQuestion: String? {
        guard !isResponding, let last = turns.last, last.role == .user else { return nil }
        return last.text
    }

    /// Removes the trailing unanswered user turn so a retry can re-send it
    /// without leaving a duplicate question bubble behind. No-op unless
    /// `retryableQuestion` is non-nil.
    /// Whether the retryable question is one whose run the app was closed during (a crash, or a
    /// suspension the background wind-down could not outrun), found by `ChatRunRecovery`.
    var retryableQuestionWasInterrupted: Bool {
        guard retryableQuestion != nil, let last = turns.last else { return false }
        return interruptedQuestionIDs.contains(last.id)
    }

    func dropRetryableQuestion() {
        guard retryableQuestion != nil else { return }
        let pending = turns.removeLast()
        retryArtifacts = pending.artifacts
        retryOrigins = pending.artifactOrigins
    }

    /// Requests cancellation of the in-flight reply. The conversation stays busy in `.cancelling`
    /// until the run settles (`waitUntilSettled`); the run itself drops the partial reply and
    /// keeps its trace, usage and committed artifacts on the retryable question.
    func cancel() {
        pendingForegroundResume = nil
        guard let task else { return }
        phase = .cancelling
        // Queued input is cleared before the stop and handed back to the composer (NH08).
        guard let queue = inputQueue else { task.cancel(); return }
        Task { [weak self] in
            let pending = (try? await queue.clear()) ?? []
            self?.restoreToDraft(pending.map(\.text))
            task.cancel()
        }
    }

    /// Starts a brand-new, unsaved conversation — the "new chat" affordance.
    /// Nothing is written until the first exchange completes (`persist()`),
    /// so an abandoned new chat never leaves an empty row in history.
    func reset() {
        cancel()
        // Fences the cancelled run: it can no longer touch what is shown from here on.
        generation = UUID()
        turns.removeAll()
        retryArtifacts = []
        retryOrigins = [:]
        error = nil
        session = nil
        interruptedQuestionIDs = []
        interruptedResume = nil
        runProgress = AgentRunProgress()
        conversationID = UUID()
        artifacts = []
        workspace = ChatDocumentWorkspace()
        scopeEditor = ChatSourceScopeEditor(meetingID: meeting?.id)
    }

    // MARK: - Session history

    /// Must be called once before `send`/`pastSessions`, from the owning
    /// view, so replies can be persisted and past ones listed. `meeting`
    /// scopes both the same way it scopes retrieval — `nil` for the
    /// library-wide "Ask".
    func configure(meeting: Meeting?, modelContext: ModelContext) {
        let changedMeeting = self.meeting?.id != meeting?.id
        if changedMeeting { reset() }
        self.meeting = meeting
        if changedMeeting || self.modelContext == nil { scopeEditor = ChatSourceScopeEditor(meetingID: meeting?.id) }
        self.modelContext = modelContext
    }

    /// Saved conversations in the current scope, most-recently-active first.
    /// Fetches every `ChatSession` and filters in memory rather than a
    /// predicate over the optional `meeting` relationship, the same
    /// resolve-scope-in-Swift shape, which is cheap for a fetch this infrequent.
    func pastSessions() -> [ChatSession] {
        guard let modelContext else { return [] }
        let all = (try? modelContext.fetch(FetchDescriptor<ChatSession>())) ?? []
        let meetingID = meeting?.id
        return all
            .filter { $0.meeting?.id == meetingID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Loads a previously saved conversation for display and continuation.
    func load(session: ChatSession) {
        guard session.meeting?.id == meeting?.id else { return }
        cancel()
        generation = UUID()
        do {
            if let modelContext { try SwiftDataAgentSessionStore(context: modelContext).migrate(session) }
            let restored = try session.harnessSnapshot()
            let workspace = try ChatDocumentWorkspace(artifacts: restored.artifacts)
            self.session = session
            conversationID = session.id
            self.workspace = workspace
            artifacts = restored.artifacts
            scopeEditor = ChatSourceScopeEditor(meetingID: meeting?.id, scope: restored.scope)
            // An interrupted run's recorded steps show under the question it left unanswered.
            let recovered = modelContext.map {
                ChatRunRecovery.restoringInterruptedRun(in: restored.turns, session: session, context: $0)
            } ?? (turns: restored.turns, interrupted: [])
            turns = recovered.turns.map(Turn.init)
            interruptedQuestionIDs = recovered.interrupted
            runProgress = AgentRunProgress()
            interruptedResume = modelContext.flatMap { context in
                ChatRunRecovery.resumableInterruptedRun(in: recovered.turns, session: session, context: context)
            }.flatMap { runID in recovered.turns.last.map { InterruptedResume(question: $0.text, runID: runID) } }
            retryArtifacts = []
            retryOrigins = [:]
            error = nil
            restoreLeftoverQueue(of: session)
        } catch {
            self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.invalid", comment: "Saved chat storage error"))
        }
    }

    func updateScope(_ scope: ChatSourceScope) {
        guard !isResponding else { return }
        scopeEditor = ChatSourceScopeEditor(meetingID: meeting?.id, scope: scope)
        if session != nil { persist() }
    }

    private func runHarness(_ agentModel: any AgentModel, runID: UUID, commandID: String, question: String,
                            history priorTurns: [Turn],
                            provider: AIProvider, model: String, startedAt: Date) async throws -> Bool {
        guard let modelContext else {
            throw AppError.apiError(statusCode: 0, message: "Chat requires a configured model context.")
        }
        let workspace = workspace
        let generation = self.generation
        // The question this run answers is the turn `send` just appended.
        let questionID = turns.last?.id
        let completedTurns = Array(turns.dropLast())
        let initialArtifacts = await workspace.snapshot()
        let origin = ChatArtifactOrigin(question: question, modelIdentifier: "\(provider.id):\(model)",
                                        sources: try ChatArtifactSources.capture(scope: scope, context: modelContext))
        let priorOrigins = Dictionary(uniqueKeysWithValues: initialArtifacts.map {
            ($0.id, ChatArtifactStore.origin(artifactID: $0.id, in: turns.map(PersistedChatTurn.init)))
        })
        try Task.checkCancellation()
        if initialArtifacts != artifacts {
            artifacts = initialArtifacts
            persist(turns: completedTurns)
        }
        var service = harnessService
        service.conversationID = conversationID
        service.documentOrigin = origin
        let acceptedTurns = turns
        service.prepareDocumentSession = { [weak self] in
            guard let self, self.generation == generation else { throw CancellationError() }
            try self.persistOrThrow(turns: acceptedTurns)
        }
        // The run's canonical history goes on its own branch of the saved session, anchored at
        // the accepted question, written by an `AgentSession` owner (`ChatRunBranch`); `runID`
        // matches the run's `ChatRunRecord`.
        let savedSession = session
        let owner = try savedSession.map {
            try ChatRunBranch.owner(session: $0, store: SwiftDataAgentSessionStore(context: modelContext))
        }
        let queue = startInputQueue()
        defer { stopInputQueue() }
        let run = try await service.start(model: agentModel, provider: provider, modelIdentifier: model,
                                          context: modelContext, scope: scope, workspace: workspace,
                                          history: Self.buildHistory(from: priorTurns), question: question,
                                          owner: owner, runID: runID, commandID: commandID, questionID: questionID,
                                          replay: ChatReplayHistory.load(
                                              turns: priorTurns.map { .init(id: $0.id, role: $0.role, text: $0.text) },
                                              session: savedSession, store: SwiftDataAgentSessionStore(context: modelContext)),
                                          inputQueue: queue)
        // Whatever ends this function, the run has settled first: a cancelled or failed run is
        // only reported once nothing can still call a tool or write its effect.
        do { try Task.checkCancellation() } catch {
            await run.terminate()
            throw error
        }
        let index = turns.count
        turns.append(Turn(role: .assistant, text: ""))
        var timeline = AgentRunTrace()
        var toolsSeen = 0
        var exchanges: [AgentRunSnapshot.Exchange] = []
        do {
            for try await view in run.snapshots {
                try Task.checkCancellation()
                if self.generation == generation {
                    runProgress = view.progress
                    phase = phase.following(runProgress)
                }
                timeline = view.trace
                turns[index].steps = timeline.steps
                turns[index].usage = timeline.hasUsage
                    ? TokenUsage(promptTokens: timeline.usage.inputTokens, completionTokens: timeline.usage.outputTokens) : nil
                turns[index].costUSD = turns[index].usage.flatMap { ModelPricing.estimatedCostUSD(model: model, usage: $0) }
                // Queued input the run took in shows as its own question and reply (NH08).
                exchanges = view.exchanges
                turns = Self.presenting(exchanges, fallback: view.text, in: turns, from: index)
                // Coalescing can fold several tool calls into one snapshot: take every one that
                // finished since the last snapshot seen.
                let finished = view.finishedTools.dropFirst(toolsSeen)
                toolsSeen = view.finishedTools.count
                if finished.contains(where: { !$0.isError && ChatRunBranch.documentTools.contains($0.name) }) {
                    let snapshot = await workspace.snapshot()
                    try Task.checkCancellation()
                    turns[index].recordArtifacts(from: artifacts, to: snapshot,
                                                origin: origin, priorOrigins: priorOrigins)
                    artifacts = snapshot
                    var pending = turns[index - 1]
                    pending.inheritArtifacts(from: turns[index])
                    persist(turns: completedTurns + [pending])
                }
            }
            try Task.checkCancellation()
            await run.settle()
        } catch {
            await run.terminate()
            if self.generation == generation { runProgress.finish() }
            // Queued input this run took in but did not finish answering goes back to the composer.
            await restoreUnansweredInput(exchanges.dropFirst().compactMap(\.input))
            // A run whose end entry alone failed to save gets one more attempt at it, without
            // re-running anything; a branch still left open is closed by the next launch sweep.
            if ChatRunBranch.isWriteFailure(error), let owner {
                try? await owner.retrySettlement()
                _ = await owner.waitUntilSettled()
            }
            let snapshot = await workspace.snapshot()
            // Any document change this run committed rules out an automatic resume.
            if snapshot != initialArtifacts { stoppedRunCommittedEffects = true }
            if self.generation == generation, snapshot != artifacts {
                turns[index - 1].recordArtifacts(from: artifacts, to: snapshot,
                                                origin: origin, priorOrigins: priorOrigins)
                artifacts = snapshot
                persist(turns: completedTurns + [turns[index - 1]])
            }
            // A run whose session was deleted under it writes nothing more and reports nothing.
            if let savedSession, savedSession.isDeleted || savedSession.modelContext == nil { throw CancellationError() }
            throw error
        }
        turns[index].elapsedSeconds = Date().timeIntervalSince(startedAt)
        // A run that stopped at a limit leaves its queue: that input goes back to the composer.
        await restoreUnansweredInput([])
        if exchanges.count <= 1, ChatRunNotice.needsRetry(steps: timeline.steps, answer: turns[index].text) {
            let stopped = turns.removeLast()
            turns[index - 1].steps = stopped.steps
            turns[index - 1].inheritArtifacts(from: stopped)
            turns[index - 1].usage = stopped.usage
            turns[index - 1].costUSD = stopped.costUSD
            turns[index - 1].elapsedSeconds = stopped.elapsedSeconds
            return false
        }
        return true
    }

    /// Permanently deletes `target`. If it was the open conversation, starts
    /// a fresh one in its place so the view doesn't keep showing turns that
    /// no longer exist on disk.
    /// Returns whether `target` was deleted, so a list can keep a refused row.
    @discardableResult
    func delete(_ target: ChatSession) -> Bool {
        guard let modelContext else { return false }
        let wasCurrent = target.id == session?.id
        // The open conversation's run writes into its session until it settles.
        guard !(wasCurrent && isResponding) else { return false }
        modelContext.delete(target)
        if let saveError = modelContext.saveOrError() {
            self.error = saveError
        }
        if wasCurrent { reset() }
        return true
    }
}
