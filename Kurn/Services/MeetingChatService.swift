//
//  MeetingChatService.swift
//  Kurn
//
//  "Chat with your meetings": retrieval-augmented Q&A over transcripts. Given a
//  question and a set of pre-embedded passages (the meeting's own chunks, or the
//  whole library for a global ask), it retrieves the most relevant passages via
//  `SemanticSearchService`, builds a grounded prompt, and asks the configured
//  cloud LLM through the existing `LLMProvider.chat` path. Pure value-in /
//  value-out — SwiftData snapshots are handed in by the `@MainActor` view model.
//

import Foundation

struct MeetingChatService {
    private let searchService: SemanticSearchService

    init(searchService: SemanticSearchService = SemanticSearchService()) {
        self.searchService = searchService
    }

    /// An answer plus the passages it was grounded on, so the UI can show
    /// tappable `[mm:ss]` citations that deep-link into the transcript.
    struct Answer: Sendable {
        var text: String
        var citations: [SemanticSearchService.Hit]
    }

    /// Number of passages fed to the model as grounding context.
    static let retrievalLimit = 8

    /// Answer `question` grounded in `candidates`. `history` carries prior
    /// user/assistant turns (without their contexts, to save tokens). Resolves
    /// the provider via `ProviderFactory.summaryProvider`, so it shares the
    /// summary provider's key gating (`AppError.noAPIKey`).
    func answer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        provider: AIProvider,
        model: String
    ) async throws -> Answer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.apiError(
                statusCode: 0,
                message: NSLocalizedString("chat.error.empty_question", comment: "Empty chat question")
            )
        }

        let hits = try await searchService.search(
            query: trimmed,
            in: candidates,
            limit: Self.retrievalLimit
        )

        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let userPrompt = Self.userPrompt(question: trimmed, hits: hits)
        var messages = history
        messages.append(ChatMessage(role: .user, content: userPrompt))

        let text = try await llm.chat(systemPrompt: Self.systemPrompt, messages: messages)
        return Answer(text: text, citations: hits)
    }

    // MARK: - Prompt building

    /// Grounding instructions: answer only from the excerpts, cite timestamps,
    /// admit when the answer isn't present, and reply in the transcript language.
    static let systemPrompt = """
    You are an assistant that answers questions about a meeting using ONLY the \
    transcript excerpts provided in each user message. Follow these rules:
    - Base your answer strictly on the excerpts. Do not invent facts or use \
    outside knowledge about the participants or topic.
    - If the excerpts do not contain the answer, say so plainly instead of \
    guessing.
    - Cite the moments you rely on using their [mm:ss] timestamps from the \
    excerpts.
    - Reply in the SAME LANGUAGE as the transcript excerpts.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    /// The per-turn user message: the question plus the retrieved passages,
    /// rendered as `[mm:ss] Speaker: text` lines the model can cite.
    static func userPrompt(question: String, hits: [SemanticSearchService.Hit]) -> String {
        guard !hits.isEmpty else {
            return """
            Question: \(question)

            No transcript excerpts matched this question. Tell the user you \
            couldn't find anything about it in the meeting.
            """
        }
        let excerpts = hits
            .map { "[\($0.start.clockDisplay)] \($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        return """
        Question: \(question)

        Relevant excerpts from the meeting transcript:
        \(excerpts)
        """
    }
}
