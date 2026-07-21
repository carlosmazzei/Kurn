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

    /// Send `question`, grounded in `candidates` (built by the view from the
    /// meeting's or library's `SemanticChunk`s). `provider`/`model` come from the
    /// summary settings. No-op while a previous reply is still in flight.
    func send(
        question: String,
        candidates: [SemanticSearchService.Candidate],
        provider: AIProvider,
        model: String
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        turns.append(Turn(role: .user, text: trimmed))
        isResponding = true
        // Prior turns as plain history (without their retrieval contexts, to
        // keep the token cost down); the current question carries fresh context.
        let history = turns.dropLast().map { ChatMessage(role: $0.role, content: $0.text) }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await chatService.answer(
                    question: trimmed,
                    history: Array(history),
                    candidates: candidates,
                    provider: provider,
                    model: model
                )
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
