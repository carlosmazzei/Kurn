//
//  MeetingChatService.swift
//  Kurn
//
//  "Chat with your meetings". Two grounding strategies:
//
//  - **Per-meeting** (`answerAboutMeeting`): a single meeting's transcript almost
//    always fits the model's context, so it is sent in full — far more accurate
//    than retrieving a handful of passages. Only meetings past the single-pass
//    budget fall back to retrieval.
//  - **Library-wide** (`answerAcrossLibrary`) and the long-meeting fallback use a
//    retrieval pipeline: LLM query rewrite → hybrid (dense + lexical) retrieval →
//    LLM rerank → grounded answer.
//
//  Pure value-in / value-out — SwiftData snapshots are handed in by the
//  `@MainActor` view model. All network work is the existing `LLMProvider.chat`.
//

import Foundation

struct MeetingChatService {
    private let searchService: SemanticSearchService

    init(searchService: SemanticSearchService = SemanticSearchService()) {
        self.searchService = searchService
    }

    /// An answer plus the passages it was grounded on (retrieval mode). In
    /// full-context mode `citations` is empty — the view makes the `[mm:ss]`
    /// timestamps the model cites tappable instead.
    struct Answer: Sendable {
        var text: String
        var citations: [SemanticSearchService.Hit]
    }

    /// Passages fed to the model after reranking.
    static let retrievalLimit = 10
    /// Candidate pool size pulled from hybrid retrieval before reranking.
    static let poolSize = 30

    // MARK: - Entry points

    /// Answer about a single meeting. Sends the whole transcript when it fits the
    /// single-pass budget; otherwise falls back to retrieval over `candidates`.
    func answerAboutMeeting(
        question: String,
        history: [ChatMessage],
        transcriptText: String,
        candidates: [SemanticSearchService.Candidate],
        provider: AIProvider,
        model: String
    ) async throws -> Answer {
        let trimmed = try Self.requireQuestion(question)
        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !transcript.isEmpty, transcript.count <= SummaryService.maxSinglePassChars {
            let userPrompt = Self.fullContextPrompt(question: trimmed, transcript: transcript)
            let text = try await llm.chat(
                systemPrompt: Self.fullContextSystemPrompt,
                messages: history + [ChatMessage(role: .user, content: userPrompt)]
            )
            return Answer(text: text, citations: [])
        }
        return try await retrievedAnswer(question: trimmed, history: history, candidates: candidates, llm: llm)
    }

    /// Answer across the whole library (the "Ask" sheet). Always retrieval.
    func answerAcrossLibrary(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        provider: AIProvider,
        model: String
    ) async throws -> Answer {
        let trimmed = try Self.requireQuestion(question)
        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        return try await retrievedAnswer(question: trimmed, history: history, candidates: candidates, llm: llm)
    }

    // MARK: - Retrieval pipeline

    private func retrievedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        llm: LLMProvider
    ) async throws -> Answer {
        // 1. Rewrite/expand the query for better dense + lexical recall (best effort).
        let expansion = try? await rewriteQuery(question, llm: llm)
        let denseText = expansion.map { "\(question)\n\($0)" } ?? question
        let lexicalQuery = expansion.map { "\(question) \($0)" } ?? question

        // 2. Hybrid retrieval → candidate pool.
        let pool = try await searchService.hybridSearch(
            query: lexicalQuery, denseText: denseText, in: candidates, poolSize: Self.poolSize
        )
        guard !pool.isEmpty else {
            let text = try await llm.chat(
                systemPrompt: Self.systemPrompt,
                messages: history + [ChatMessage(role: .user, content: Self.userPrompt(question: question, hits: []))]
            )
            return Answer(text: text, citations: [])
        }

        // 3. Rerank with the LLM (best effort; degrade to fused order).
        let top = (try? await rerank(question: question, pool: pool, llm: llm))
            ?? Array(pool.prefix(Self.retrievalLimit))

        // 4. Grounded answer.
        let userPrompt = Self.userPrompt(question: question, hits: top)
        let text = try await llm.chat(
            systemPrompt: Self.systemPrompt,
            messages: history + [ChatMessage(role: .user, content: userPrompt)]
        )
        return Answer(text: text, citations: top)
    }

    /// One LLM call producing extra search terms / a hypothetical answer sentence
    /// to widen recall. Returns nil when the model gives nothing useful.
    private func rewriteQuery(_ question: String, llm: LLMProvider) async throws -> String? {
        let system = """
        You expand a user's question into search keywords to retrieve matching \
        transcript passages. Reply with ONLY a short line of keywords and, \
        optionally, one hypothetical answer sentence — in the SAME LANGUAGE as \
        the question. No labels, no quotes, no JSON.
        """
        let reply = try await llm.chat(
            systemPrompt: system,
            messages: [ChatMessage(role: .user, content: question)]
        )
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(400))
    }

    /// One LLM call selecting the most relevant passages from the pool. Returns
    /// the reranked top passages, or nil if the reply can't be parsed.
    private func rerank(
        question: String,
        pool: [SemanticSearchService.Hit],
        llm: LLMProvider
    ) async throws -> [SemanticSearchService.Hit]? {
        let numbered = pool.enumerated()
            .map { "\($0.offset + 1). [\($0.element.start.clockDisplay)] \($0.element.speakerLabel): \($0.element.text)" }
            .joined(separator: "\n")
        let system = """
        You rank transcript passages by relevance to a question. Reply with ONLY \
        the numbers of the most relevant passages, most relevant first, comma- \
        separated (e.g. "4, 1, 9"). Pick at most \(Self.retrievalLimit). Omit \
        passages that are irrelevant.
        """
        let user = "Question: \(question)\n\nPassages:\n\(numbered)"
        let reply = try await llm.chat(systemPrompt: system, messages: [ChatMessage(role: .user, content: user)])

        let picks = Self.parseIndices(reply, max: pool.count)
        guard !picks.isEmpty else { return nil }
        return picks.prefix(Self.retrievalLimit).map { pool[$0] }
    }

    /// Distinct absolute-second timestamps the model cited as `[mm:ss]` or
    /// `[h:mm:ss]`, in order of first appearance. Used to make the timestamps in
    /// a full-context answer tappable (there are no retrieval `Hit`s there).
    static func citedTimestamps(in text: String) -> [TimeInterval] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [TimeInterval] = []
        var seen = Set<Int>()
        for match in regex.matches(in: text, range: range) {
            func group(_ i: Int) -> Int? {
                guard let r = Range(match.range(at: i), in: text) else { return nil }
                return Int(text[r])
            }
            let seconds: Int
            if let third = group(3), let first = group(1), let second = group(2) {
                seconds = first * 3600 + second * 60 + third
            } else if let first = group(1), let second = group(2) {
                seconds = first * 60 + second
            } else {
                continue
            }
            if seen.insert(seconds).inserted { result.append(TimeInterval(seconds)) }
        }
        return result
    }

    /// Parse 1-based indices from a free-form reply into unique 0-based indices
    /// within `[0, max)`, preserving order.
    static func parseIndices(_ reply: String, max: Int) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for token in reply.components(separatedBy: CharacterSet.decimalDigits.inverted) {
            guard let value = Int(token) else { continue }
            let index = value - 1
            guard index >= 0, index < max, seen.insert(index).inserted else { continue }
            result.append(index)
        }
        return result
    }

    // MARK: - Prompts

    private static func requireQuestion(_ question: String) throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.apiError(
                statusCode: 0,
                message: NSLocalizedString("chat.error.empty_question", comment: "Empty chat question")
            )
        }
        return trimmed
    }

    /// Grounding for the full-transcript path.
    static let fullContextSystemPrompt = """
    You are an assistant that answers questions about a meeting using the \
    transcript provided in the user message. Follow these rules:
    - Base your answer on the transcript. Do not invent facts or use outside \
    knowledge about the participants or topic.
    - If the transcript does not contain the answer, say so plainly.
    - Cite the moments you rely on using their [mm:ss] timestamps from the \
    transcript.
    - Reply in the SAME LANGUAGE as the transcript.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    static func fullContextPrompt(question: String, transcript: String) -> String {
        """
        Question: \(question)

        Meeting transcript (each line is "[mm:ss] Speaker: text"):
        \(transcript)
        """
    }

    /// Grounding for the retrieval path: answer only from the excerpts.
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

    /// The per-turn user message for the retrieval path: the question plus the
    /// retrieved passages, rendered as `[mm:ss] Speaker: text` lines to cite.
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
