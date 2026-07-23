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
    var error: AppError?

    private let chatService = MeetingChatService()
    private var task: Task<Void, Never>?

    /// Send `question`. When `transcriptText` is non-nil the scope is a single
    /// meeting (full-transcript grounding, falling back to retrieval over
    /// `candidates` only for very long meetings); when nil the scope is the whole
    /// library (retrieval over `candidates`). `provider`/`model` come from the
    /// summary settings. No-op while a previous reply is still in flight.
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
        let history = Self.buildHistory(from: Array(turns.dropLast()))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: MeetingChatService.Answer
                if let transcriptText {
                    answer = try await chatService.answerAboutMeeting(
                        question: trimmed, history: history, transcriptText: transcriptText,
                        candidates: candidates, provider: provider, model: model
                    )
                } else {
                    answer = try await chatService.answerAcrossLibrary(
                        question: trimmed, history: history, candidates: candidates,
                        summariesByMeeting: summariesByMeeting, articlesByMeeting: articlesByMeeting,
                        provider: provider, model: model
                    )
                }
                self.turns.append(Turn(role: .assistant, text: answer.text, citations: answer.citations))
            } catch is CancellationError {
                // User cancelled; drop the pending assistant turn silently.
            } catch let appError as AppError {
                self.error = appError
            } catch {
                self.error = .apiError(statusCode: 0, message: error.localizedDescription)
            }
            self.isResponding = false
            self.task = nil
        }
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
