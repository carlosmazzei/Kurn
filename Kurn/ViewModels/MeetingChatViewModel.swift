//
//  MeetingChatViewModel.swift
//  Kurn
//
//  Drives "chat with your meetings": owns the in-memory conversation, gathers
//  the pre-embedded passages to search over, and calls `MeetingChatService` for
//  a grounded answer. All SwiftData reads happen on the main actor; the
//  retrieval + LLM call run off-main in the service.
//
//  A conversation is also the unit of persistence: `configure(meeting:modelContext:)`
//  wires up the `ChatSession` scope (per-meeting or library-wide), and a
//  successfully completed exchange is saved into `session` — created lazily on
//  the first one, so a conversation the user opens and abandons never leaves an
//  empty row in the history list. Only finished exchanges are persisted; a
//  cancelled or failed reply is dropped from `turns` (see `dropPartialReply`)
//  before `persist()` would ever see it.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class MeetingChatViewModel {
    /// One rendered turn in the conversation.
    struct Turn: Identifiable {
        let id: UUID
        let role: ChatMessage.Role
        var text: String
        var citations: [SemanticSearchService.Hit] = []
        /// Token usage the provider reported for this reply, and its
        /// estimated USD cost (`ModelPricing`, `nil` for an unrecognized
        /// model) — both `nil` until the reply finishes, and permanently
        /// `nil` for a provider/response that never reports usage.
        var usage: TokenUsage?
        var costUSD: Double?
        /// Wall-clock time the reply took to fully generate, set once it
        /// finishes.
        var elapsedSeconds: TimeInterval?

        /// `id` defaults to a fresh `UUID` for a brand-new turn; restoring a
        /// saved one (`Turn.init(_ persisted:)` below) passes its stored id
        /// through instead, so a turn's identity survives a save/load
        /// round trip.
        init(
            id: UUID = UUID(),
            role: ChatMessage.Role,
            text: String,
            citations: [SemanticSearchService.Hit] = [],
            usage: TokenUsage? = nil,
            costUSD: Double? = nil,
            elapsedSeconds: TimeInterval? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.citations = citations
            self.usage = usage
            self.costUSD = costUSD
            self.elapsedSeconds = elapsedSeconds
        }
    }

    private(set) var turns: [Turn] = []
    private(set) var isResponding = false
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
    /// The pipeline stage currently reported by `MeetingChatService`, shown as
    /// a "reasoning" row while the assistant's turn has no text yet. Cleared
    /// once the reply starts streaming (the growing text bubble replaces it)
    /// and whenever a turn finishes, errors, or is cancelled.
    private(set) var currentPhase: ChatPhase?
    /// Supplementary detail for `currentPhase`, e.g. "(2/5)" while a
    /// large-library "Ask" works through several blocks of meeting notes —
    /// see `ChatStreamEvent.progress`. Cleared alongside `currentPhase`.
    private(set) var currentPhaseDetail: String?
    var error: AppError?

    private let chatService = MeetingChatService()
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

    /// Send `question`. When `transcriptText` is non-nil the scope is a single
    /// meeting (full-transcript grounding, falling back to retrieval over
    /// `candidates` only for very long meetings); when nil the scope is the whole
    /// library (retrieval over `candidates`). `provider`/`model` come from the
    /// summary settings. No-op while a previous reply is still in flight.
    ///
    /// The reply streams in: `MeetingChatService` reports `ChatStreamEvent`s
    /// from off the main actor, so they are bridged through an `AsyncStream`
    /// into a single `@MainActor` consumer task that applies them in order —
    /// the same pattern `TranscriptionViewModel` uses for transcription
    /// phases. The assistant `Turn` is created lazily, on the first text
    /// delta, so an error before any text arrives leaves no stray turn behind.
    func send(
        question: String,
        transcriptText: String?,
        candidates: [SemanticSearchService.Candidate],
        summariesByMeeting: [UUID: String] = [:],
        articlesByMeeting: [UUID: WikiArticleSnapshot] = [:],
        provider: AIProvider,
        model: String
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        turns.append(Turn(role: .user, text: trimmed))
        isResponding = true
        currentPhase = nil
        currentPhaseDetail = nil
        let history = Self.buildHistory(from: Array(turns.dropLast()))
        // Streaming can append a partial assistant turn before cancellation is
        // observed (unlike the old atomic-answer flow, which only appended on
        // success). Remember where the reply would start so a cancel can drop
        // it, keeping the "silently drop the pending turn" behavior intact.
        let turnCountBeforeReply = turns.count
        // `runID` correlates every `ReliabilityEvent` this turn produces — the
        // service's own per-stage events (validation, provider, answer) and
        // this view model's own outcome event below — the same
        // caller-generates-the-id convention `DocumentGenerationViewModel`
        // uses for `DocumentGenerationService`.
        let runID = OperationID()
        let startedAt = Date()

        let (stream, continuation) = AsyncStream<ChatStreamEvent>.makeStream()
        let onEvent: MeetingChatService.ChatEventHandler = { event in
            continuation.yield(event)
        }
        let consumer = Task { @MainActor [weak self] in
            var assistantIndex: Int?
            for await event in stream {
                guard let self else { return }
                switch event {
                case .phase(let phase):
                    self.currentPhase = phase
                    self.currentPhaseDetail = nil
                case .progress(let detail):
                    self.currentPhaseDetail = detail
                case .delta(let text):
                    if assistantIndex == nil {
                        self.currentPhase = nil
                        self.currentPhaseDetail = nil
                        self.turns.append(Turn(role: .assistant, text: ""))
                        assistantIndex = self.turns.count - 1
                    }
                    if let assistantIndex {
                        self.turns[assistantIndex].text += text
                    }
                }
            }
        }

        // Close the channel and wait for the consumer to apply every pending
        // event before touching completion/error state, the same
        // `drainEvents` idiom `TranscriptionViewModel` uses for its own
        // off-main phase callbacks.
        func drainEvents() async {
            continuation.finish()
            await consumer.value
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: MeetingChatService.Answer
                if let transcriptText {
                    answer = try await chatService.answerAboutMeeting(
                        question: trimmed, history: history, transcriptText: transcriptText,
                        candidates: candidates, provider: provider, model: model,
                        runID: runID, onEvent: onEvent
                    )
                } else {
                    answer = try await chatService.answerAcrossLibrary(
                        question: trimmed, history: history, candidates: candidates,
                        summariesByMeeting: summariesByMeeting, articlesByMeeting: articlesByMeeting,
                        provider: provider, model: model, runID: runID, onEvent: onEvent
                    )
                }
                await drainEvents()
                self.applyFinal(answer, model: model, elapsed: Date().timeIntervalSince(startedAt))
                // Reported at "view_model" stage, distinct from the service's
                // own unstaged success event — the same two-tier shape
                // `DocumentGenerationViewModel`/`DocumentGenerationService`
                // use (one signal per layer: did the API call succeed, did
                // the whole user-visible round trip succeed).
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
            } catch is CancellationError {
                // User cancelled; drop whatever streamed in so far, silently.
                // Leaving the question turn in place is what makes it
                // `retryableQuestion` afterward.
                await drainEvents()
                self.dropPartialReply(keeping: turnCountBeforeReply)
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
            } catch let appError as AppError {
                // Same drop as cancellation: a half-streamed answer next to
                // an error alert reads as a broken reply, not a retryable
                // question, so `retryableQuestion` needs the turn list back
                // at just the question for this to be one clean asset.
                await drainEvents()
                self.dropPartialReply(keeping: turnCountBeforeReply)
                self.error = appError
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: appError.logCode
                ))
            } catch {
                await drainEvents()
                self.dropPartialReply(keeping: turnCountBeforeReply)
                self.error = .apiError(statusCode: 0, message: error.localizedDescription)
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "meeting_chat", stage: "view_model",
                    outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: "unexpected"
                ))
            }
            self.isResponding = false
            self.currentPhase = nil
            self.currentPhaseDetail = nil
            self.task = nil
        }
    }

    /// Replace the streamed-in assistant text with the service's final answer
    /// (they should already match) and attach its citations, which only
    /// arrive with the completed `Answer` — streaming deltas carry text only.
    /// Also attaches the provider's token usage (if it reported one), the
    /// estimated cost that implies under `model`, and how long the reply
    /// took to generate.
    private func applyFinal(_ answer: MeetingChatService.Answer, model: String, elapsed: TimeInterval) {
        guard let index = turns.lastIndex(where: { $0.role == .assistant }) else { return }
        turns[index].text = answer.text
        turns[index].citations = answer.citations
        turns[index].usage = answer.usage
        turns[index].elapsedSeconds = elapsed
        turns[index].costUSD = answer.usage.flatMap { ModelPricing.estimatedCostUSD(model: model, usage: $0) }
        persist()
    }

    // MARK: - Persistence

    /// Saves the whole conversation so far into `session`, creating it (and
    /// deriving its title from the first question) on the first successful
    /// exchange. Never called for a cancelled/failed reply — `dropPartialReply`
    /// removes those turns before `applyFinal`, the only caller, is reached.
    /// A save failure is logged and surfaced but leaves the conversation on
    /// screen exactly as it is — the user's answer is not lost, only its
    /// persistence.
    private func persist() {
        guard let modelContext else { return }
        let target: ChatSession
        if let session {
            target = session
        } else {
            let firstQuestion = turns.first(where: { $0.role == .user })?.text ?? ""
            target = ChatSession(meeting: meeting, title: ChatSession.title(from: firstQuestion))
            modelContext.insert(target)
            session = target
        }
        target.turns = turns.map(PersistedChatTurn.init)
        target.updatedAt = Date()
        if let saveError = modelContext.saveOrError() {
            self.error = saveError
        }
    }

    /// Removes any turn appended after `count` — the partial assistant reply
    /// a cancellation or failure leaves behind — so the conversation reads as
    /// "the question is still unanswered" rather than a broken half-answer
    /// sitting next to an error. Leaves the question turn itself untouched.
    private func dropPartialReply(keeping count: Int) {
        guard turns.count > count else { return }
        turns.removeLast(turns.count - count)
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
        turns.removeLast()
    }

    /// Prior turns as chat history. Turns are plain text to keep token cost
    /// down, but the most recent answer's retrieved excerpts are re-appended as a
    /// compact context block so follow-up questions stay grounded in what the
    /// previous answer was based on. (Full per-turn context is intentionally not
    /// kept — that is the synthesis path's job, not the lookup path's.)
    static func buildHistory(from prior: [Turn]) -> [ChatMessage] {
        var history = prior.map { ChatMessage(role: $0.role, content: $0.text) }
        if let lastAnswer = prior.last(where: { $0.role == .assistant }),
           !lastAnswer.citations.isEmpty {
            history.append(ChatMessage(role: .user, content: contextBlock(from: lastAnswer.citations)))
        }
        return history
    }

    /// A short, bounded reminder of the excerpts the previous answer used.
    private static func contextBlock(from hits: [SemanticSearchService.Hit]) -> String {
        let lines = hits.prefix(8).map { hit -> String in
            let meeting = hit.meetingTitle.isEmpty ? "" : " (\(hit.meetingTitle))"
            return "[\(hit.start.clockDisplay)]\(meeting) \(hit.speakerLabel): \(hit.text)"
        }.joined(separator: "\n")
        return "For reference, my previous answer was grounded on these excerpts:\n\(lines)"
    }

    /// Cancel an in-flight reply.
    func cancel() {
        task?.cancel()
        task = nil
        isResponding = false
    }

    /// Starts a brand-new, unsaved conversation — the "new chat" affordance.
    /// Nothing is written until the first exchange completes (`persist()`),
    /// so an abandoned new chat never leaves an empty row in history.
    func reset() {
        cancel()
        turns.removeAll()
        error = nil
        session = nil
    }

    // MARK: - Session history

    /// Must be called once before `send`/`pastSessions`, from the owning
    /// view, so replies can be persisted and past ones listed. `meeting`
    /// scopes both the same way it scopes retrieval — `nil` for the
    /// library-wide "Ask".
    func configure(meeting: Meeting?, modelContext: ModelContext) {
        self.meeting = meeting
        self.modelContext = modelContext
    }

    /// Saved conversations in the current scope, most-recently-active first.
    /// Fetches every `ChatSession` and filters in memory rather than a
    /// predicate over the optional `meeting` relationship, the same
    /// resolve-scope-in-Swift shape `MeetingChatView`'s own
    /// `summariesByMeeting`/`articlesByMeeting` already use for a fetch this
    /// infrequent.
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
        cancel()
        self.session = session
        turns = session.turns.map(Turn.init)
        error = nil
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

private extension PersistedChatTurn {
    /// Snapshot of a rendered `Turn` for JSON storage.
    init(_ turn: MeetingChatViewModel.Turn) {
        self.init(
            id: turn.id,
            role: turn.role,
            text: turn.text,
            citations: turn.citations.map(PersistedCitation.init),
            usage: turn.usage,
            costUSD: turn.costUSD,
            elapsedSeconds: turn.elapsedSeconds
        )
    }
}

private extension PersistedCitation {
    init(_ hit: SemanticSearchService.Hit) {
        self.init(
            meetingID: hit.meetingID,
            recordingID: hit.recordingID,
            meetingTitle: hit.meetingTitle,
            start: hit.start,
            speakerLabel: hit.speakerLabel,
            text: hit.text
        )
    }
}

private extension MeetingChatViewModel.Turn {
    /// Restores a rendered `Turn` from a saved session. `end`/`score` have no
    /// persisted counterpart (unused once retrieval ranking is done), so
    /// reconstructed citations zero them — display and jump-to-citation only
    /// ever read `start`/`speakerLabel`/`text`/the two ids.
    init(_ persisted: PersistedChatTurn) {
        self.init(
            id: persisted.id,
            role: persisted.role,
            text: persisted.text,
            citations: persisted.citations.map { citation in
                SemanticSearchService.Hit(
                    chunkID: UUID(),
                    meetingID: citation.meetingID,
                    recordingID: citation.recordingID,
                    text: citation.text,
                    start: citation.start,
                    end: citation.start,
                    speakerLabel: citation.speakerLabel,
                    score: 0,
                    meetingTitle: citation.meetingTitle
                )
            },
            usage: persisted.usage,
            costUSD: persisted.costUSD,
            elapsedSeconds: persisted.elapsedSeconds
        )
    }
}
