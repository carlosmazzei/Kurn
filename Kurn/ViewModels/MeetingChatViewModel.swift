//
//  MeetingChatViewModel.swift
//  Kurn
//
//  Drives "chat with your meetings": owns the in-memory conversation, gathers
//  the pre-embedded passages to search over, and calls `MeetingChatService` for
//  a grounded answer. History lives only in memory for the session — nothing is
//  written to disk, so there is nothing here to encrypt. All SwiftData reads
//  happen on the main actor; the retrieval + LLM call run off-main in the
//  service.
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
        let id = UUID()
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
    }

    private(set) var turns: [Turn] = []
    private(set) var isResponding = false
    /// The pipeline stage currently reported by `MeetingChatService`, shown as
    /// a "reasoning" row while the assistant's turn has no text yet. Cleared
    /// once the reply starts streaming (the growing text bubble replaces it)
    /// and whenever a turn finishes, errors, or is cancelled.
    private(set) var currentPhase: ChatPhase?
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
                case .delta(let text):
                    if assistantIndex == nil {
                        self.currentPhase = nil
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

    /// Clear the conversation.
    func reset() {
        cancel()
        turns.removeAll()
        error = nil
    }
}
