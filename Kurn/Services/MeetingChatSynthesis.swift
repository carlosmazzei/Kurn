//
//  MeetingChatSynthesis.swift
//  Kurn
//
//  The library-wide chat's synthesis path, split out of `MeetingChatService` to
//  keep that file under SwiftLint's length limit. Where the retrieval path
//  answers pinpoint lookups from a handful of transcript passages, this answers
//  questions that span, compare, or aggregate across meetings by reasoning over
//  the condensed per-meeting wiki articles.
//
//  Because articles are condensed (~1–4 KB each, not whole transcripts), many of
//  them fit the single-pass budget, so the model can genuinely count and
//  cross-reference. When the selected articles exceed the budget they are packed
//  — whole, never split mid-article — into blocks and processed map-reduce, the
//  same shape as `SummaryService.mapReduce`.
//

import Foundation

extension MeetingChatService {

    /// Meetings whose articles are considered for a synthesis answer.
    static let synthesisMeetingLimit = 16

    /// Answer a cross-meeting question over the condensed wiki articles. Falls
    /// back to the retrieval path when no articles are available to reason over.
    func synthesizedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        articles: [UUID: WikiArticleSnapshot],
        summariesByMeeting: [UUID: String],
        llm: LLMProvider
    ) async throws -> Answer {
        let selected = try await selectArticles(
            question: question, candidates: candidates, articles: articles, llm: llm
        )
        guard !selected.isEmpty else {
            return try await retrievedAnswer(
                question: question, history: history, candidates: candidates,
                scope: .library, summariesByMeeting: summariesByMeeting, llm: llm
            )
        }
        let text = try await synthesize(question: question, history: history, articles: selected, llm: llm)
        return Answer(text: text, citations: [])
    }

    // MARK: - Article selection

    /// Pick the articles to reason over: every article for a global aggregate,
    /// otherwise the top retrieval-ranked meetings that have an article.
    private func selectArticles(
        question: String,
        candidates: [SemanticSearchService.Candidate],
        articles: [UUID: WikiArticleSnapshot],
        llm: LLMProvider
    ) async throws -> [WikiArticleSnapshot] {
        if QuestionRouter.isGlobalAggregate(question) {
            return Array(articles.values)
        }
        let expansion = try? await rewriteQuery(question, llm: llm)
        let denseText = expansion.map { "\(question)\n\($0)" } ?? question
        let lexicalQuery = expansion.map { "\(question) \($0)" } ?? question
        let pool = try await searchService.hybridSearch(
            query: lexicalQuery, denseText: denseText, in: candidates, poolSize: Self.libraryPoolSize
        )
        var selected: [WikiArticleSnapshot] = []
        for hit in SemanticSearchService.diversify(pool, maxPerMeeting: 1) {
            guard let article = articles[hit.meetingID] else { continue }
            selected.append(article)
            if selected.count >= Self.synthesisMeetingLimit { break }
        }
        // Retrieval found no article-backed meetings (e.g. embedder unavailable) —
        // fall back to a bounded slice of whatever articles exist.
        if selected.isEmpty { selected = Array(articles.values.prefix(Self.synthesisMeetingLimit)) }
        return selected
    }

    // MARK: - Synthesis (single pass or map-reduce over whole articles)

    private func synthesize(
        question: String,
        history: [ChatMessage],
        articles: [WikiArticleSnapshot],
        llm: LLMProvider
    ) async throws -> String {
        let rendered = articles.map { Self.renderArticle($0) }
        // Fits in one pass → a single call that can count/aggregate directly.
        if Self.packArticles(rendered, maxChars: SummaryService.maxSinglePassChars).count <= 1 {
            let block = rendered.joined(separator: "\n\n")
            let userPrompt = Self.synthesisUserPrompt(question: question, articlesBlock: block)
            return try await llm.chat(
                systemPrompt: Self.synthesisSystemPrompt,
                messages: history + [ChatMessage(role: .user, content: userPrompt)]
            )
        }
        // Otherwise map-reduce over whole-article blocks.
        let blocks = Self.packArticles(rendered, maxChars: SummaryService.mapBlockChars)
        return try await synthesizeMapReduce(question: question, history: history, blocks: blocks, llm: llm)
    }

    private func synthesizeMapReduce(
        question: String,
        history: [ChatMessage],
        blocks: [String],
        llm: LLMProvider
    ) async throws -> String {
        var partials: [String] = []
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            let userPrompt = Self.synthesisMapPrompt(
                question: question, articlesBlock: block, part: index + 1, total: blocks.count
            )
            let partial = try await llm.chat(
                systemPrompt: Self.synthesisMapSystemPrompt,
                messages: [ChatMessage(role: .user, content: userPrompt)]
            )
            partials.append(partial)
        }
        try Task.checkCancellation()
        let combined = partials.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        let reducePrompt = Self.synthesisReducePrompt(question: question, partials: combined)
        return try await llm.chat(
            systemPrompt: Self.synthesisSystemPrompt,
            messages: history + [ChatMessage(role: .user, content: reducePrompt)]
        )
    }

    // MARK: - Rendering / packing

    /// One article as a `### <title> — <date>` heading followed by its notes.
    static func renderArticle(_ article: WikiArticleSnapshot) -> String {
        let title = article.title.isEmpty
            ? NSLocalizedString("chat.untitled_meeting", comment: "Fallback name for a meeting without a title")
            : article.title
        let head = article.date == .distantPast
            ? "### \(title)"
            : "### \(title) — \(article.date.formatted(date: .abbreviated, time: .omitted))"
        return "\(head)\n\(article.bodyMarkdown)"
    }

    /// Greedily pack whole rendered articles into blocks of at most `maxChars`,
    /// never splitting an article. An article larger than `maxChars` becomes its
    /// own oversized block rather than being cut.
    static func packArticles(_ rendered: [String], maxChars: Int) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var count = 0
        for article in rendered {
            let added = current.isEmpty ? article.count : article.count + 2 // "\n\n"
            if !current.isEmpty && count + added > maxChars {
                blocks.append(current.joined(separator: "\n\n"))
                current = [article]
                count = article.count
            } else {
                current.append(article)
                count += added
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n\n")) }
        return blocks
    }

    // MARK: - Prompts

    static let synthesisSystemPrompt = """
    You are an assistant that answers questions across a personal library of \
    meetings. You are given condensed per-meeting notes, each headed by its \
    meeting title and date ("### <title> — <date>"). These notes are complete \
    structured records of each meeting, so you CAN count, aggregate, compare, \
    and find themes across meetings. Follow these rules:
    - Attribute findings to meetings by naming their title (and date when useful).
    - When counting or aggregating, be exhaustive over the notes provided and \
    state the number.
    - Base your answer strictly on the notes. Do not invent facts or use outside \
    knowledge.
    - Preserve any [mm:ss] timestamps when you cite a specific moment.
    - Reply in the SAME LANGUAGE as the notes.
    - Be well-organized: use short headings or bullets when comparing meetings.
    """

    static func synthesisUserPrompt(question: String, articlesBlock: String) -> String {
        """
        Question: \(question)

        Condensed notes for the relevant meetings:
        \(articlesBlock)
        """
    }

    static let synthesisMapSystemPrompt = """
    You are extracting everything relevant to a question from condensed \
    per-meeting notes, each headed by its meeting title and date. Keep \
    per-meeting attribution (title + date) and any exact numbers, names, and \
    [mm:ss] timestamps. Do not write the final answer or editorialize — just \
    pull out the relevant facts, grouped by meeting. Reply in the SAME LANGUAGE \
    as the notes.
    """

    static func synthesisMapPrompt(
        question: String, articlesBlock: String, part: Int, total: Int
    ) -> String {
        """
        Question: \(question)

        Meeting notes (part \(part) of \(total)):
        \(articlesBlock)
        """
    }

    static func synthesisReducePrompt(question: String, partials: String) -> String {
        """
        Question: \(question)

        The relevant meetings were processed in parts; the per-part findings \
        (with meeting attribution) are below. Combine them into one answer: sum \
        any counts, merge themes, and keep per-meeting attribution.

        Findings:
        \(partials)
        """
    }
}
