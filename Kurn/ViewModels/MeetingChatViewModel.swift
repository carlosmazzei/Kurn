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

    // H8 PR 20: `deinit` is nonisolated even on a `@MainActor` class (Swift
    // gives it no way to hop actors before the object is gone), so cancelling
    // `task` there needs unchecked access — confirmed by CI, which rejected
    // a plain `private var task` with "main actor-isolated property 'task'
    // can not be referenced from a nonisolated context". This is the same
    // "the compiler can't prove it, but it's fine" shape PR 18 already
    // resolved for `LockScreenRecordingController.activity`: every other
    // access to `task` (`send`/`cancel`/`reset`) is already isolated to the
    // main actor as normal, and the one added by `deinit` can't race them —
    // `deinit` only runs once the object's refcount reaches zero, and the
    // task's own closure holds a strong reference to `self` (via its
    // `guard let self`) for as long as it's actively mutating state, which
    // makes that reference and deinit mutually exclusive by construction.
    // `@ObservationIgnored` keeps this a plain stored property; behind the
    // `@Observable` accessors `nonisolated(unsafe)` would have no effect.
    @ObservationIgnored private nonisolated(unsafe) var task: Task<Void, Never>?

    /// H8 PR 20, item 1's "chat/search tasks cancel on dismissal": this view
    /// model is owned by `MeetingChatView`'s `@State`, so SwiftUI deallocates
    /// it when the chat tab/sheet leaves the hierarchy — but nothing
    /// previously cancelled `task` when that happened, so a reply already in
    /// flight (a paid cloud LLM call) kept running to completion in the
    /// background after the user navigated away. `deinit` is the reliable
    /// backstop regardless of which dismissal path was taken.
    deinit {
        task?.cancel()
    }

    /// Tests pass a scripted `AgentModel` through `agentModelFactory`.
    init(agentModelFactory: @escaping HarnessChatService.ModelFactory = { try ProviderFactory.agentModel(for: $0, model: $1) },
         harnessService: HarnessChatService = HarnessChatService()) {
        self.agentModelFactory = agentModelFactory
        self.harnessService = harnessService
    }

    /// Send `question` to the agent over the current source scope. `provider`/`model` come from
    /// the summary settings. No-op while a previous reply is still in flight. A provider without
    /// an `AgentModel` (Apple's on-device model) fails with the cloud-provider notice; the view
    /// disables the composer for it before that can happen.
    func send(question: String, provider: AIProvider, model: String, runID: OperationID = OperationID()) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        error = nil

        generation = UUID()
        let generation = self.generation

        turns.append(Turn(role: .user, text: trimmed))
        turns[turns.count - 1].artifacts = retryArtifacts
        turns[turns.count - 1].artifactOrigins = retryOrigins
        retryArtifacts = []
        retryOrigins = [:]
        isResponding = true
        let priorTurns = Array(turns.dropLast())
        // A cancel or failure drops whatever reply was appended after the question, so the
        // question stays as the retryable, unanswered turn.
        let turnCountBeforeReply = turns.count
        // `runID` correlates the `ReliabilityEvent` this turn produces; a parameter (defaulted) so
        // a test can pick its own events out of the process-global log.
        let startedAt = Date()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard let agentModel = try agentModelFactory(provider, model) else {
                    throw AppError.apiError(statusCode: 0, message: NSLocalizedString(
                        "chat.artifact.cloud_required", comment: "Chat provider requirement"))
                }
                let answered = try await self.runHarness(agentModel, question: trimmed,
                                                         history: Self.buildHistory(from: priorTurns),
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
                let appError = error as? AppError ?? .apiError(statusCode: 0, message: error.localizedDescription)
                if self.generation == generation {
                    self.dropPartialReply(keeping: turnCountBeforeReply)
                    self.error = appError
                }
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: error is AppError ? appError.logCode : "unexpected"
                ))
            }
            guard self.generation == generation else { return }
            self.isResponding = false
            self.task = nil
        }
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
        catch { self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.invalid", comment: "Saved chat storage error")) }
    }

    private func persistOrThrow(turns savedTurns: [Turn]? = nil) throws {
        guard let modelContext else { return }
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
    func dropRetryableQuestion() {
        guard retryableQuestion != nil else { return }
        let pending = turns.removeLast()
        retryArtifacts = pending.artifacts
        retryOrigins = pending.artifactOrigins
    }

    /// Prior turns as plain user/assistant history; old tool payloads are never replayed.
    static func buildHistory(from prior: [Turn]) -> [ChatMessage] {
        prior.map { ChatMessage(role: $0.role, content: $0.text) }
    }

    /// Cancel an in-flight reply.
    func cancel() {
        task?.cancel()
        task = nil
        if isResponding, turns.last?.role == .assistant { dropPartialReply(keeping: turns.count - 1) }
        isResponding = false
    }

    /// Starts a brand-new, unsaved conversation — the "new chat" affordance.
    /// Nothing is written until the first exchange completes (`persist()`),
    /// so an abandoned new chat never leaves an empty row in history.
    func reset() {
        cancel()
        generation = UUID()
        turns.removeAll()
        retryArtifacts = []
        retryOrigins = [:]
        error = nil
        session = nil
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
            turns = restored.turns.map(Turn.init)
            retryArtifacts = []
            retryOrigins = [:]
            error = nil
        } catch {
            self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.invalid", comment: "Saved chat storage error"))
        }
    }

    func updateScope(_ scope: ChatSourceScope) {
        guard !isResponding else { return }
        scopeEditor = ChatSourceScopeEditor(meetingID: meeting?.id, scope: scope)
        if session != nil { persist() }
    }

    private func runHarness(_ agentModel: any AgentModel, question: String, history: [ChatMessage],
                            provider: AIProvider, model: String, startedAt: Date) async throws -> Bool {
        guard let modelContext else {
            throw AppError.apiError(statusCode: 0, message: "Chat requires a configured model context.")
        }
        let workspace = workspace
        let generation = self.generation
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
        let events = try await service.events(model: agentModel, provider: provider, modelIdentifier: model,
                                                     context: modelContext, scope: scope, workspace: workspace,
                                                     history: history, question: question)
        try Task.checkCancellation()
        let index = turns.count
        turns.append(Turn(role: .assistant, text: ""))
        var timeline = AgentRunTrace()
        do {
            for try await event in events {
                try Task.checkCancellation()
                timeline.apply(event)
                turns[index].steps = timeline.steps
                turns[index].usage = timeline.hasUsage
                    ? TokenUsage(promptTokens: timeline.usage.inputTokens, completionTokens: timeline.usage.outputTokens) : nil
                turns[index].costUSD = turns[index].usage.flatMap { ModelPricing.estimatedCostUSD(model: model, usage: $0) }
                switch event {
                case .textDelta(let text): turns[index].text += text
                case .runFinished(let outcome): turns[index].text = outcome.finalText
                case .toolFinished(_, let name, _, let isError):
                    if !isError && ["create_document", "update_document", "append_to_document"].contains(name) {
                        let snapshot = await workspace.snapshot()
                        try Task.checkCancellation()
                        turns[index].recordArtifacts(from: artifacts, to: snapshot,
                                                    origin: origin, priorOrigins: priorOrigins)
                        artifacts = snapshot
                        var pending = turns[index - 1]
                        pending.inheritArtifacts(from: turns[index])
                        persist(turns: completedTurns + [pending])
                    }
                default: break
                }
            }
            try Task.checkCancellation()
        } catch {
            let snapshot = await workspace.snapshot()
            if self.generation == generation, snapshot != artifacts {
                turns[index - 1].recordArtifacts(from: artifacts, to: snapshot,
                                                origin: origin, priorOrigins: priorOrigins)
                artifacts = snapshot
                persist(turns: completedTurns + [turns[index - 1]])
            }
            throw error
        }
        turns[index].elapsedSeconds = Date().timeIntervalSince(startedAt)
        if ChatRunNotice.needsRetry(steps: timeline.steps, answer: turns[index].text) {
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
    func delete(_ target: ChatSession) {
        guard let modelContext else { return }
        let wasCurrent = target.id == session?.id
        modelContext.delete(target)
        if let saveError = modelContext.saveOrError() {
            self.error = saveError
        }
        if wasCurrent { reset() }
    }
}
