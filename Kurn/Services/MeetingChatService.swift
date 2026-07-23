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
    // Not `private`: the synthesis path in `MeetingChatSynthesis.swift` (a
    // separate file) reuses the same retrieval helpers, and `private` is
    // file-scoped.
    let searchService: SemanticSearchService

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

    /// Whether retrieval is grounding a single meeting or the whole library.
    /// Library scope diversifies across meetings and attributes each excerpt to
    /// its source meeting; single-meeting scope keeps the original behaviour.
    enum Scope {
        case singleMeeting
        case library
    }

    /// Passages fed to the model after reranking (single-meeting scope).
    static let retrievalLimit = 10
    /// Candidate pool size pulled from hybrid retrieval before reranking.
    static let poolSize = 30
    /// Wider pool for the library-wide "Ask": more meetings can contribute.
    static let libraryPoolSize = 60
    /// Larger answer window for the library so synthesis has more to work with.
    static let libraryRetrievalLimit = 20
    /// Cap on excerpts kept from any single meeting before reranking, so one
    /// highly-relevant meeting can't crowd out the rest of the library.
    static let maxHitsPerMeeting = 3

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
        return try await retrievedAnswer(
            question: trimmed, history: history, candidates: candidates, scope: .singleMeeting, llm: llm
        )
    }

    /// Answer across the whole library (the "Ask" sheet). Routes the question:
    /// pinpoint **lookups** go through library-scope retrieval (excerpts
    /// diversified across meetings, attributed to their source meeting, with any
    /// `summariesByMeeting` overviews); **synthesis/aggregate** questions are
    /// answered over the condensed `articlesByMeeting` wiki articles, which can
    /// count and cross-reference. When no articles are available the router
    /// always chooses retrieval, so this degrades gracefully to the Phase-A path.
    func answerAcrossLibrary(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        summariesByMeeting: [UUID: String] = [:],
        articlesByMeeting: [UUID: WikiArticleSnapshot] = [:],
        provider: AIProvider,
        model: String
    ) async throws -> Answer {
        let trimmed = try Self.requireQuestion(question)
        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)

        let route: QuestionRouter.Route = articlesByMeeting.isEmpty
            ? .lookup
            : await QuestionRouter.classify(trimmed, llm: llm)

        switch route {
        case .lookup:
            return try await retrievedAnswer(
                question: trimmed, history: history, candidates: candidates,
                scope: .library, summariesByMeeting: summariesByMeeting, llm: llm
            )
        case .synthesis:
            return try await synthesizedAnswer(
                question: trimmed, history: history, candidates: candidates,
                articles: articlesByMeeting, summariesByMeeting: summariesByMeeting, llm: llm
            )
        }
    }

    // MARK: - Retrieval pipeline

    // Not `private`: reused by the synthesis fallback in `MeetingChatSynthesis.swift`.
    func retrievedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        scope: Scope,
        summariesByMeeting: [UUID: String] = [:],
        llm: LLMProvider
    ) async throws -> Answer {
        let poolSize = scope == .library ? Self.libraryPoolSize : Self.poolSize
        let limit = scope == .library ? Self.libraryRetrievalLimit : Self.retrievalLimit

        // 1. Rewrite/expand the query for better dense + lexical recall (best effort).
        let expansion = try? await rewriteQuery(question, llm: llm)
        let denseText = expansion.map { "\(question)\n\($0)" } ?? question
        let lexicalQuery = expansion.map { "\(question) \($0)" } ?? question

        // 2. Hybrid retrieval → candidate pool.
        var pool = try await searchService.hybridSearch(
            query: lexicalQuery, denseText: denseText, in: candidates, poolSize: poolSize
        )
        guard !pool.isEmpty else {
            let empty = Self.userPrompt(question: question, hits: [], scope: scope, summaries: [:])
            let text = try await llm.chat(
                systemPrompt: Self.systemPrompt(for: scope),
                messages: history + [ChatMessage(role: .user, content: empty)]
            )
            return Answer(text: text, citations: [])
        }

        // 2b. Diversify across meetings so the rerank sees breadth, not ten
        // passages from one meeting (library scope only).
        if scope == .library {
            pool = SemanticSearchService.diversify(pool, maxPerMeeting: Self.maxHitsPerMeeting)
        }

        // 3. Rerank with the LLM (best effort; degrade to fused order).
        let top = (try? await rerank(question: question, pool: pool, limit: limit, llm: llm))
            ?? Array(pool.prefix(limit))

        // 4. Grounded answer.
        let userPrompt = Self.userPrompt(question: question, hits: top, scope: scope, summaries: summariesByMeeting)
        let text = try await llm.chat(
            systemPrompt: Self.systemPrompt(for: scope),
            messages: history + [ChatMessage(role: .user, content: userPrompt)]
        )
        return Answer(text: text, citations: top)
    }

    /// One LLM call producing extra search terms / a hypothetical answer sentence
    /// to widen recall. Returns nil when the model gives nothing useful.
    // Not `private`: reused by the synthesis path in `MeetingChatSynthesis.swift`.
    func rewriteQuery(_ question: String, llm: LLMProvider) async throws -> String? {
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
        limit: Int,
        llm: LLMProvider
    ) async throws -> [SemanticSearchService.Hit]? {
        let numbered = pool.enumerated()
            .map { "\($0.offset + 1). [\($0.element.start.clockDisplay)] \($0.element.speakerLabel): \($0.element.text)" }
            .joined(separator: "\n")
        let system = """
        You rank transcript passages by relevance to a question. Reply with ONLY \
        the numbers of the most relevant passages, most relevant first, comma- \
        separated (e.g. "4, 1, 9"). Pick at most \(limit). Omit \
        passages that are irrelevant.
        """
        let user = "Question: \(question)\n\nPassages:\n\(numbered)"
        let reply = try await llm.chat(systemPrompt: system, messages: [ChatMessage(role: .user, content: user)])

        let picks = Self.parseIndices(reply, max: pool.count)
        guard !picks.isEmpty else { return nil }
        return picks.prefix(limit).map { pool[$0] }
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

    /// Grounding for the library-wide retrieval path: excerpts span several
    /// meetings, each headed by its title and date, so the model must attribute
    /// and compare across meetings.
    static let librarySystemPrompt = """
    You are an assistant that answers questions across a personal library of \
    meetings, using ONLY the meeting overviews and transcript excerpts provided \
    in each user message. Follow these rules:
    - Each excerpt is grouped under the meeting it came from, headed by \
    "### <meeting title> — <date>". Attribute every claim to a meeting by \
    naming its title (and date when useful).
    - When a question spans meetings, compare and connect what the different \
    meetings say.
    - Base your answer strictly on the provided overviews and excerpts. Do not \
    invent facts or use outside knowledge about the participants or topics.
    - If the material does not contain the answer, say so plainly instead of \
    guessing.
    - Cite the moments you rely on using their [mm:ss] timestamps.
    - Reply in the SAME LANGUAGE as the excerpts.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    /// The system prompt for a retrieval scope.
    static func systemPrompt(for scope: Scope) -> String {
        switch scope {
        case .singleMeeting: return systemPrompt
        case .library: return librarySystemPrompt
        }
    }

    /// The per-turn user message for the retrieval path: the question plus the
    /// retrieved passages. Single-meeting scope renders plain `[mm:ss] Speaker:
    /// text` lines; library scope groups them by meeting (with title/date headers
    /// and any per-meeting overviews) so the model can attribute across meetings.
    static func userPrompt(
        question: String,
        hits: [SemanticSearchService.Hit],
        scope: Scope,
        summaries: [UUID: String]
    ) -> String {
        guard !hits.isEmpty else { return emptyPrompt(question: question, scope: scope) }
        switch scope {
        case .singleMeeting:
            let excerpts = hits
                .map { "[\($0.start.clockDisplay)] \($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")
            return """
            Question: \(question)

            Relevant excerpts from the meeting transcript:
            \(excerpts)
            """
        case .library:
            return libraryUserPrompt(question: question, hits: hits, summaries: summaries)
        }
    }

    /// The message when nothing matched, phrased for the scope.
    private static func emptyPrompt(question: String, scope: Scope) -> String {
        let closing = scope == .library
            ? "couldn't find anything about it across their meetings."
            : "couldn't find anything about it in the meeting."
        return """
        Question: \(question)

        No transcript excerpts matched this question. Tell the user you \
        \(closing)
        """
    }

    /// Group hits by meeting, ordered by their best-ranked appearance.
    private static func groupByMeeting(
        _ hits: [SemanticSearchService.Hit]
    ) -> [(id: UUID, hits: [SemanticSearchService.Hit])] {
        var order: [UUID] = []
        var grouped: [UUID: [SemanticSearchService.Hit]] = [:]
        for hit in hits {
            if grouped[hit.meetingID] == nil { order.append(hit.meetingID) }
            grouped[hit.meetingID, default: []].append(hit)
        }
        return order.map { (id: $0, hits: grouped[$0] ?? []) }
    }

    /// A `### <title> — <date>` header for the meeting a hit belongs to.
    private static func meetingHeader(_ hit: SemanticSearchService.Hit) -> String {
        let title = hit.meetingTitle.isEmpty
            ? NSLocalizedString("chat.untitled_meeting", comment: "Fallback name for a meeting without a title")
            : hit.meetingTitle
        guard hit.meetingDate != .distantPast else { return "### \(title)" }
        return "### \(title) — \(hit.meetingDate.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Library-wide user message: optional per-meeting overviews, then excerpts
    /// grouped and attributed by meeting.
    private static func libraryUserPrompt(
        question: String,
        hits: [SemanticSearchService.Hit],
        summaries: [UUID: String]
    ) -> String {
        let groups = groupByMeeting(hits)
        let excerpts = groups.map { group -> String in
            let head = group.hits.first.map(meetingHeader) ?? "###"
            let lines = group.hits
                .map { "[\($0.start.clockDisplay)] \($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")
            return "\(head)\n\(lines)"
        }.joined(separator: "\n\n")

        let overviews = groups.compactMap { group -> String? in
            guard let summary = summaries[group.id], !summary.isEmpty,
                  let head = group.hits.first.map(meetingHeader) else { return nil }
            return "\(head)\n\(summary)"
        }.joined(separator: "\n\n")

        var prompt = "Question: \(question)\n"
        if !overviews.isEmpty {
            prompt += "\nMeeting overviews (condensed summaries of the meetings the excerpts below come from):\n\(overviews)\n"
        }
        prompt += "\nRelevant excerpts, grouped by meeting (each headed by its title and date):\n\(excerpts)"
        return prompt
    }
}
