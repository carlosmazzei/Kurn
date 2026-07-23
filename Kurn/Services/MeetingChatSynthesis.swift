//
//  MeetingChatSynthesis.swift
//  Kurn
//
//  The library-wide chat's combined answer, split out of `MeetingChatService` to
//  keep that file under SwiftLint's length limit. Rather than route a question to
//  either retrieval or the wiki, it gives the model BOTH in one grounded prompt:
//  the retrieved verbatim excerpts (for exact quotes and `[mm:ss]` citations) and
//  the condensed per-meeting wiki articles of the meetings in play (for
//  synthesis, comparison, and counting). The model uses whichever it needs, so
//  hybrid questions ("what did we decide about X and how did it evolve") are
//  answered in a single pass.
//
//  Because articles are condensed (~1–4 KB each, not whole transcripts), the
//  articles of a handful of meetings plus the excerpts fit the single-pass
//  budget. When they don't — chiefly a global aggregate over a large library —
//  the articles are packed whole (never split) into blocks and map-reduced, the
//  same shape as `SummaryService.mapReduce`, with the excerpts carried into the
//  reduce for citation. Citations are always the retrieved passages, so the
//  answer keeps tappable `[mm:ss]` chips even for a synthesis answer.
//

import Foundation

extension MeetingChatService {

    /// Meetings whose articles are considered for a non-global answer.
    static let synthesisMeetingLimit = 16

    /// Answer a library-wide question over the retrieved excerpts and the wiki
    /// articles of the meetings in play (all articles for a global aggregate).
    func libraryCombinedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        summaries: [UUID: String],
        articles: [UUID: WikiArticleSnapshot],
        llm: LLMProvider
    ) async throws -> Answer {
        let passages = try await retrievePassages(
            question: question, candidates: candidates,
            poolSize: Self.libraryPoolSize, limit: Self.libraryRetrievalLimit, diversify: true, llm: llm
        )
        let selected = Self.selectArticles(question: question, passages: passages, articles: articles)

        guard !passages.isEmpty || !selected.isEmpty else {
            let empty = Self.userPrompt(question: question, hits: [], scope: .library, summaries: [:])
            let text = try await llm.chat(
                systemPrompt: Self.systemPrompt(for: .library),
                messages: history + [ChatMessage(role: .user, content: empty)]
            )
            return Answer(text: text, citations: [])
        }

        let rendered = selected.map(Self.renderArticle)
        let passagesBlock = Self.renderPassages(passages)
        let overviews = Self.overviewsBlock(passages: passages, summaries: summaries, selected: selected)
        let userPrompt = Self.combinedUserPrompt(
            question: question, articlesBlock: rendered.joined(separator: "\n\n"),
            passagesBlock: passagesBlock, overviewsBlock: overviews
        )

        // Fits in one pass → a single call that can quote and aggregate directly.
        if userPrompt.count <= SummaryService.maxSinglePassChars {
            let text = try await llm.chat(
                systemPrompt: Self.combinedSystemPrompt,
                messages: history + [ChatMessage(role: .user, content: userPrompt)]
            )
            return Answer(text: text, citations: passages)
        }

        // Otherwise map-reduce over whole-article blocks, carrying the excerpts.
        let blocks = Self.packArticles(rendered, maxChars: SummaryService.mapBlockChars)
        let text = try await synthesizeMapReduce(
            question: question, history: history, blocks: blocks, passagesBlock: passagesBlock, llm: llm
        )
        return Answer(text: text, citations: passages)
    }

    // MARK: - Article selection

    /// The articles to reason over: every article for a global aggregate,
    /// otherwise the articles of the meetings that surfaced in the excerpts (in
    /// passage-rank order, capped at `synthesisMeetingLimit`).
    static func selectArticles(
        question: String,
        passages: [SemanticSearchService.Hit],
        articles: [UUID: WikiArticleSnapshot]
    ) -> [WikiArticleSnapshot] {
        guard !articles.isEmpty else { return [] }
        if LibraryQuestion.isGlobalAggregate(question) {
            return Array(articles.values)
        }
        var selected: [WikiArticleSnapshot] = []
        for group in groupByMeeting(passages) {
            guard let article = articles[group.id] else { continue }
            selected.append(article)
            if selected.count >= synthesisMeetingLimit { break }
        }
        return selected
    }

    // MARK: - Map-reduce (over whole articles, for the overflow case)

    private func synthesizeMapReduce(
        question: String,
        history: [ChatMessage],
        blocks: [String],
        passagesBlock: String,
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
        let reducePrompt = Self.combinedReducePrompt(
            question: question, partials: combined, passagesBlock: passagesBlock
        )
        return try await llm.chat(
            systemPrompt: Self.combinedSystemPrompt,
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

    /// The retrieved excerpts grouped by meeting under their title/date headers,
    /// or an empty string when there are none.
    static func renderPassages(_ passages: [SemanticSearchService.Hit]) -> String {
        guard !passages.isEmpty else { return "" }
        return groupByMeeting(passages).map { group -> String in
            let head = group.hits.first.map(meetingHeader) ?? "###"
            let lines = group.hits
                .map { "[\($0.start.clockDisplay)] \($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")
            return "\(head)\n\(lines)"
        }.joined(separator: "\n\n")
    }

    /// Condensed summaries for passage meetings that don't yet have a wiki
    /// article, so an unindexed meeting still contributes an overview.
    static func overviewsBlock(
        passages: [SemanticSearchService.Hit],
        summaries: [UUID: String],
        selected: [WikiArticleSnapshot]
    ) -> String {
        let hasArticle = Set(selected.map(\.meetingID))
        return groupByMeeting(passages).compactMap { group -> String? in
            guard !hasArticle.contains(group.id),
                  let summary = summaries[group.id], !summary.isEmpty,
                  let head = group.hits.first.map(meetingHeader) else { return nil }
            return "\(head)\n\(summary)"
        }.joined(separator: "\n\n")
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

    static let combinedSystemPrompt = """
    You are an assistant that answers questions across a personal library of \
    meetings. Each user message gives you two things, both grouped by meeting \
    under "### <title> — <date>" headers:
    - CONDENSED NOTES: complete structured notes per meeting. Use these to \
    synthesize, compare across meetings, and count/aggregate. When counting, be \
    exhaustive over the notes provided and state the number.
    - VERBATIM EXCERPTS: exact transcript lines. Use these for direct quotes and \
    cite the moments you rely on with their [mm:ss] timestamps.
    Rules:
    - Attribute every claim to a meeting by naming its title (and date when useful).
    - Base your answer strictly on the notes and excerpts. Do not invent facts or \
    use outside knowledge about the participants or topics.
    - If the material does not contain the answer, say so plainly.
    - Reply in the SAME LANGUAGE as the material.
    - Be well-organized: use short headings or bullets when comparing meetings.
    """

    static func combinedUserPrompt(
        question: String, articlesBlock: String, passagesBlock: String, overviewsBlock: String
    ) -> String {
        var prompt = "Question: \(question)\n"
        if !articlesBlock.isEmpty {
            prompt += "\nCondensed notes per meeting:\n\(articlesBlock)\n"
        }
        if !overviewsBlock.isEmpty {
            prompt += "\nAdditional meeting overviews (not yet in the notes above):\n\(overviewsBlock)\n"
        }
        if !passagesBlock.isEmpty {
            prompt += "\nVerbatim excerpts to quote and cite [mm:ss]:\n\(passagesBlock)"
        }
        return prompt
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

    static func combinedReducePrompt(question: String, partials: String, passagesBlock: String) -> String {
        var prompt = """
        Question: \(question)

        The relevant meetings were processed in parts; the per-part findings \
        (with meeting attribution) are below. Combine them into one answer: sum \
        any counts, merge themes, and keep per-meeting attribution.

        Findings:
        \(partials)
        """
        if !passagesBlock.isEmpty {
            prompt += "\n\nVerbatim excerpts to quote and cite [mm:ss]:\n\(passagesBlock)"
        }
        return prompt
    }
}
