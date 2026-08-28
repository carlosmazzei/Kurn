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
import KurnCore

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
    private static let cloudRetrievalLimit = 10
    /// Candidate pool size pulled from hybrid retrieval before reranking.
    private static let cloudPoolSize = 30
    /// Wider pool for the library-wide "Ask": more meetings can contribute.
    private static let cloudLibraryPoolSize = 60
    /// Larger answer window for the library so synthesis has more to work with.
    private static let cloudLibraryRetrievalLimit = 20

    /// On-device sizes are much smaller than the cloud ones above. Unlike the
    /// library-wide answer (which falls back to map-reduce when its prompt
    /// doesn't fit, per `SummaryService.maxSinglePassChars(for:)`),
    /// `retrievedAnswer`'s single-meeting answer has no such fallback — its
    /// prompt must fit the small on-device context window directly. The
    /// rerank prompt lists every pooled passage in full, so the pool itself
    /// must also stay small. Conservative first-cut figures, not measured.
    private static let onDeviceRetrievalLimit = 4
    private static let onDevicePoolSize = 10
    private static let onDeviceLibraryPoolSize = 15
    private static let onDeviceLibraryRetrievalLimit = 6

    /// Passages fed to the model after reranking (single-meeting scope).
    static func retrievalLimit(for provider: AIProvider) -> Int {
        provider.kind == .appleOnDevice ? onDeviceRetrievalLimit : cloudRetrievalLimit
    }
    /// Candidate pool size pulled from hybrid retrieval before reranking.
    static func poolSize(for provider: AIProvider) -> Int {
        provider.kind == .appleOnDevice ? onDevicePoolSize : cloudPoolSize
    }
    /// Wider pool for the library-wide "Ask": more meetings can contribute.
    static func libraryPoolSize(for provider: AIProvider) -> Int {
        provider.kind == .appleOnDevice ? onDeviceLibraryPoolSize : cloudLibraryPoolSize
    }
    /// Larger answer window for the library so synthesis has more to work with.
    static func libraryRetrievalLimit(for provider: AIProvider) -> Int {
        provider.kind == .appleOnDevice ? onDeviceLibraryRetrievalLimit : cloudLibraryRetrievalLimit
    }
    /// Cap on excerpts kept from any single meeting before reranking, so one
    /// highly-relevant meeting can't crowd out the rest of the library.
    static let maxHitsPerMeeting = 3

    /// How many top cosine hits to scan when choosing which meetings' wiki
    /// articles feed the library synthesis. Large so the relevance floor — not
    /// this cap — decides breadth.
    static let librarySynthesisPoolSize = 400
    /// Minimum cosine similarity for a meeting's best passage to include that
    /// meeting's article in the synthesis. The single knob that makes breadth
    /// adaptive: a pinpoint question clears it for few meetings, a broad topic
    /// or aggregate for many.
    static let meetingRelevanceFloor: Float = 0.2
    /// Upper bound on meetings whose articles enter one synthesis, to cap cost.
    static let maxSynthesisMeetings = 40

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

        if !transcript.isEmpty, transcript.count <= SummaryService.maxSinglePassChars(for: provider) {
            let userPrompt = Self.fullContextPrompt(question: trimmed, transcript: transcript)
            let text = try await llm.chat(
                systemPrompt: Self.fullContextSystemPrompt,
                messages: history + [ChatMessage(role: .user, content: userPrompt)]
            )
            return Answer(text: text, citations: [])
        }
        return try await retrievedAnswer(
            question: trimmed, history: history, candidates: candidates, llm: llm
        )
    }

    /// Answer across the whole library (the "Ask" sheet). Gives the model BOTH
    /// the retrieved verbatim excerpts (for exact quotes and `[mm:ss]` citations)
    /// AND the condensed wiki articles of the meetings in play (for synthesis,
    /// comparison, and counting) in one grounded prompt — no lookup-vs-synthesis
    /// routing. When no articles are available (wiki off/empty) it degrades to
    /// excerpts only, i.e. the Phase-A retrieval path. See
    /// `MeetingChatSynthesis.swift` for the combined answer.
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
        return try await libraryCombinedAnswer(
            question: trimmed, history: history, candidates: candidates,
            summaries: summariesByMeeting, articles: articlesByMeeting, llm: llm
        )
    }

    // MARK: - Retrieval pipeline

    /// Retrieve the top passages for `question`: query rewrite → hybrid retrieval
    /// → optional per-meeting diversification → LLM rerank (degrading to fused
    /// order). Shared by the single-meeting fallback and the library combined
    /// answer. Not `private`: the latter lives in `MeetingChatSynthesis.swift`.
    func retrievePassages(
        question: String,
        candidates: [SemanticSearchService.Candidate],
        poolSize: Int,
        limit: Int,
        diversify: Bool,
        llm: LLMProvider
    ) async throws -> [SemanticSearchService.Hit] {
        let expansion = try? await rewriteQuery(question, llm: llm)
        let denseText = expansion.map { "\(question)\n\($0)" } ?? question
        let lexicalQuery = expansion.map { "\(question) \($0)" } ?? question

        var pool = try await searchService.hybridSearch(
            query: lexicalQuery, denseText: denseText, in: candidates, poolSize: poolSize
        )
        guard !pool.isEmpty else { return [] }
        if diversify {
            pool = SemanticSearchService.diversify(pool, maxPerMeeting: Self.maxHitsPerMeeting)
        }
        return (try? await rerank(question: question, pool: pool, limit: limit, llm: llm))
            ?? Array(pool.prefix(limit))
    }

    /// Distinct meetings whose best passage is semantically relevant to the
    /// question — the meetings whose wiki articles feed the library synthesis.
    /// Breadth is adaptive: only meetings clearing `meetingRelevanceFloor` are
    /// included (few for a pinpoint question, many for a broad topic/aggregate),
    /// most-relevant first, capped at `maxSynthesisMeetings`. Uses dense cosine
    /// (`SemanticSearchService.search`) so the floor is a comparable similarity,
    /// not an RRF rank. Not `private`: called from `MeetingChatSynthesis.swift`.
    func selectRelevantMeetings(
        question: String,
        candidates: [SemanticSearchService.Candidate]
    ) async throws -> [UUID] {
        let hits = try await searchService.search(
            query: question, in: candidates,
            limit: Self.librarySynthesisPoolSize, minScore: Self.meetingRelevanceFloor
        )
        return SemanticSearchService.bestPerMeeting(hits)
            .prefix(Self.maxSynthesisMeetings)
            .map(\.meetingID)
    }

    /// Retrieval-grounded answer over a single meeting's passages (the
    /// long-meeting fallback for `answerAboutMeeting`).
    private func retrievedAnswer(
        question: String,
        history: [ChatMessage],
        candidates: [SemanticSearchService.Candidate],
        llm: LLMProvider
    ) async throws -> Answer {
        let top = try await retrievePassages(
            question: question, candidates: candidates,
            poolSize: Self.poolSize(for: llm.provider), limit: Self.retrievalLimit(for: llm.provider), diversify: false, llm: llm
        )
        let userPrompt = Self.userPrompt(question: question, hits: top, scope: .singleMeeting, summaries: [:])
        let text = try await llm.chat(
            systemPrompt: Self.systemPrompt(for: .singleMeeting),
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
            .map { "\($0.offset + 1). \($0.element.promptLine)" }
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
            let excerpts = hits.map(\.promptLine).joined(separator: "\n")
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
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func groupByMeeting(
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

    /// Excerpts grouped under their meeting's `### <title> — <date>` header.
    /// `chronological` orders the groups oldest-first (what the synthesis path
    /// wants, so the excerpts line up with the wiki articles); otherwise groups
    /// keep retrieval order, best-ranked meeting first.
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func renderGroupedExcerpts(
        _ hits: [SemanticSearchService.Hit],
        chronological: Bool = false
    ) -> String {
        var groups = groupByMeeting(hits)
        if chronological {
            groups.sort {
                ($0.hits.first?.meetingDate ?? .distantPast) < ($1.hits.first?.meetingDate ?? .distantPast)
            }
        }
        return groups.map { group -> String in
            let head = group.hits.first.map(meetingHeader) ?? "###"
            let lines = group.hits.map(\.promptLine).joined(separator: "\n")
            return "\(head)\n\(lines)"
        }.joined(separator: "\n\n")
    }

    /// A `### <title> — <date>` header for the meeting a hit belongs to.
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func meetingHeader(_ hit: SemanticSearchService.Hit) -> String {
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
        let excerpts = renderGroupedExcerpts(hits)

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
