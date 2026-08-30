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
    private var task: Task<Void, Never>?

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
                        candidates: candidates, provider: provider, model: model, onEvent: onEvent
                    )
                } else {
                    answer = try await chatService.answerAcrossLibrary(
                        question: trimmed, history: history, candidates: candidates,
                        summariesByMeeting: summariesByMeeting, articlesByMeeting: articlesByMeeting,
                        provider: provider, model: model, onEvent: onEvent
                    )
                }
                await drainEvents()
                self.applyFinal(answer)
            } catch is CancellationError {
                // User cancelled; drop whatever streamed in so far, silently.
                await drainEvents()
                if self.turns.count > turnCountBeforeReply {
                    self.turns.removeLast(self.turns.count - turnCountBeforeReply)
                }
            } catch let appError as AppError {
                await drainEvents()
                self.error = appError
            } catch {
                await drainEvents()
                self.error = .apiError(statusCode: 0, message: error.localizedDescription)
            }
            self.isResponding = false
            self.currentPhase = nil
            self.task = nil
        }
    }

    /// Replace the streamed-in assistant text with the service's final answer
    /// (they should already match) and attach its citations, which only
    /// arrive with the completed `Answer` — streaming deltas carry text only.
    private func applyFinal(_ answer: MeetingChatService.Answer) {
        guard let index = turns.lastIndex(where: { $0.role == .assistant }) else { return }
        turns[index].text = answer.text
        turns[index].citations = answer.citations
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
