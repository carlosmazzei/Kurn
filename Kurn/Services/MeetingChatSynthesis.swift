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
import KurnCore

extension MeetingChatService {

    /// Answer a library-wide question over the retrieved excerpts and the wiki
    /// articles of the meetings in play (all articles for a global aggregate).
    func libraryCombinedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        summaries: [UUID: String],
        articles: [UUID: WikiArticleSnapshot],
        llm: LLMProvider,
        onEvent: @escaping ChatEventHandler = { _ in },
        runID: OperationID
    ) async throws -> Answer {
        let passages = try await retrievePassages(
            question: question, candidates: candidates,
            poolSize: Self.libraryPoolSize(for: llm.provider), limit: Self.libraryRetrievalLimit(for: llm.provider), diversify: true, llm: llm,
            onEvent: onEvent
        )
        // Adaptive breadth: the wiki articles of every meeting whose best passage
        // clears the relevance floor, ordered chronologically. One path serves
        // pinpoint, evolution, and aggregate questions — the floor decides how
        // wide it goes, not a per-type classifier.
        onEvent(.phase(.synthesizing))
        let meetingIDs = try await selectRelevantMeetings(question: question, candidates: candidates)
        let selected = Self.orderedArticles(meetingIDs: meetingIDs, articles: articles)

        guard !passages.isEmpty || !selected.isEmpty else {
            let empty = Self.userPrompt(question: question, hits: [], scope: .library, summaries: [:])
            let result = try await streamAnswer(
                systemPrompt: Self.systemPrompt(for: .library),
                messages: history + [ChatMessage(role: .user, content: empty)],
                llm: llm, onEvent: onEvent, runID: runID
            )
            return Answer(text: result.text, citations: [], usage: result.usage)
        }

        let rendered = selected.map(Self.renderArticle)
        let passagesBlock = Self.renderPassages(passages)
        let overviews = Self.overviewsBlock(passages: passages, summaries: summaries, selected: selected)
        let userPrompt = Self.combinedUserPrompt(
            question: question, articlesBlock: rendered.joined(separator: "\n\n"),
            passagesBlock: passagesBlock, overviewsBlock: overviews
        )

        // Fits in one pass → a single call that can quote and aggregate directly.
        if userPrompt.count <= SummaryService.maxSinglePassChars(for: llm.provider) {
            let result = try await streamAnswer(
                systemPrompt: Self.combinedSystemPrompt,
                messages: history + [ChatMessage(role: .user, content: userPrompt)],
                llm: llm, onEvent: onEvent, runID: runID
            )
            return Answer(text: result.text, citations: passages, usage: result.usage)
        }

        // Otherwise map-reduce over whole-article blocks, carrying the excerpts.
        let blocks = Self.packArticles(rendered, maxChars: SummaryService.mapBlockChars(for: llm.provider))
        let result = try await synthesizeMapReduce(
            question: question, history: history, blocks: blocks, passagesBlock: passagesBlock, llm: llm,
            onEvent: onEvent, runID: runID
        )
        return Answer(text: result.text, citations: passages, usage: result.usage)
    }

    // MARK: - Article selection

    /// The wiki articles for `meetingIDs`, dropping meetings that don't have one,
    /// ordered chronologically (oldest first) so an evolution question reads as a
    /// timeline and every other question is unaffected by the order.
    static func orderedArticles(
        meetingIDs: [UUID],
        articles: [UUID: WikiArticleSnapshot]
    ) -> [WikiArticleSnapshot] {
        meetingIDs.compactMap { articles[$0] }.sorted { $0.date < $1.date }
    }

    // MARK: - Map-reduce (over whole articles, for the overflow case)

    private func synthesizeMapReduce(
        question: String,
        history: [ChatMessage],
        blocks: [String],
        passagesBlock: String,
        llm: LLMProvider,
        onEvent: @escaping ChatEventHandler,
        runID: OperationID
    ) async throws -> (text: String, usage: TokenUsage?) {
        onEvent(.phase(.synthesizing))
        let partials = try await Self.condenseBlocksConcurrently(
            question: question, blocks: blocks, llm: llm, onEvent: onEvent, runID: runID
        )
        try Task.checkCancellation()
        let combined = partials.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        let reducePrompt = Self.combinedReducePrompt(
            question: question, partials: combined, passagesBlock: passagesBlock
        )
        return try await streamAnswer(
            systemPrompt: Self.combinedSystemPrompt,
            messages: history + [ChatMessage(role: .user, content: reducePrompt)],
            llm: llm, onEvent: onEvent, runID: runID
        )
    }

    /// Upper bound on simultaneous map calls, so a large library doesn't fire
    /// dozens of requests at the provider at once and trip a rate limit.
    private static let maxConcurrentMapCalls = 4

    /// Condenses every block concurrently (bounded by `maxConcurrentMapCalls`)
    /// instead of one at a time. Safe to parallelize here — unlike
    /// `SummaryService.mapReduce`, which stays sequential specifically so a
    /// long-running *background* summary can checkpoint and resume block by
    /// block across app suspension, this is a live, interactive chat call
    /// with no resume path, so sequential order buys nothing but a slower
    /// wait. Progress is reported by completion count rather than start
    /// order, since with several calls in flight at once "starting block 3"
    /// is no longer a meaningful milestone the way "3 of 5 done" still is.
    /// Not `private`: covered directly by
    /// `MeetingChatSynthesisConcurrencyTests`, which scripts an `LLMProvider`
    /// and checks the reordering-by-index logic without needing to also
    /// fabricate retrieval/embedding fixtures to reach it indirectly.
    static func condenseBlocksConcurrently(
        question: String,
        blocks: [String],
        llm: LLMProvider,
        onEvent: @escaping ChatEventHandler,
        runID: OperationID
    ) async throws -> [String] {
        var results = [String?](repeating: nil, count: blocks.count)
        var completedCount = 0
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            func addTask(_ index: Int) {
                let block = blocks[index]
                group.addTask {
                    try await Self.condenseBlock(
                        question: question, block: block, index: index, total: blocks.count,
                        llm: llm, runID: runID
                    )
                }
            }

            while nextIndex < min(maxConcurrentMapCalls, blocks.count) {
                addTask(nextIndex)
                nextIndex += 1
            }

            while let (index, partial) = try await group.next() {
                results[index] = partial
                completedCount += 1
                // A large library can mean several map calls before there's
                // any other visible change — without this, "Reading meeting
                // notes…" sits static long enough to read as stuck. Skipped
                // for a single block, where there's nothing to count.
                if blocks.count > 1 {
                    onEvent(.progress(String(format: NSLocalizedString(
                        "chat.phase.progress_fraction", comment: "Step N of M within a chat phase"
                    ), completedCount, blocks.count)))
                }
                if nextIndex < blocks.count {
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }
        }
        // Every index in 0..<blocks.count had exactly one task added and
        // awaited above, so every slot is filled.
        return results.compactMap { $0 }
    }

    /// Condenses one block, reporting a `"map_N_of_M"`-stage reliability
    /// event on cancellation or failure — the same per-block granularity the
    /// previous sequential loop reported, just from a task that may now be
    /// running alongside its siblings rather than alone.
    private static func condenseBlock(
        question: String,
        block: String,
        index: Int,
        total: Int,
        llm: LLMProvider,
        runID: OperationID
    ) async throws -> (Int, String) {
        try Task.checkCancellation()
        let userPrompt = Self.synthesisMapPrompt(
            question: question, articlesBlock: block, part: index + 1, total: total
        )
        let stage = "map_\(index + 1)_of_\(total)"
        let startedAt = Date()
        do {
            let partial = try await llm.chat(
                systemPrompt: Self.synthesisMapSystemPrompt,
                messages: [ChatMessage(role: .user, content: userPrompt)]
            )
            return (index, partial)
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: stage,
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw CancellationError()
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: stage,
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: MeetingChatService.errorCode(error)
            ))
            throw error
        }
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
    /// ordered chronologically to match the articles, or an empty string when
    /// there are none.
    static func renderPassages(_ passages: [SemanticSearchService.Hit]) -> String {
        guard !passages.isEmpty else { return "" }
        return renderGroupedExcerpts(passages, chronological: true)
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
        SummaryService.packWholeItems(rendered, maxChars: maxChars)
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
    - The meetings are given in chronological order (oldest first). When the \
    question is about how something changed or evolved over time, narrate the \
    progression and call out what changed between meetings, with their dates.
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
