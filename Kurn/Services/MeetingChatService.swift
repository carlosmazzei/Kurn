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
    private let providerResolver: ProviderFactory.LLMResolver
    /// Decides whether a whole transcript (or the library synthesis prompt)
    /// fits one request; see `ContextBudget.resolve`.
    let budgetResolver: ContextBudget.Resolver

    /// `resolveProvider` resolves through `ProviderFactory` in production,
    /// exactly like `SummaryService`; tests inject a scripted provider.
    init(
        searchService: SemanticSearchService = SemanticSearchService(),
        resolveProvider: @escaping ProviderFactory.LLMResolver = ProviderFactory.liveLLM,
        resolveBudget: @escaping ContextBudget.Resolver = ContextBudget.live
    ) {
        self.searchService = searchService
        self.providerResolver = resolveProvider
        self.budgetResolver = resolveBudget
    }

    /// Progress/streaming callback fired as an answer is retrieved and
    /// generated. May be called from a background executor; the receiver hops
    /// to the main actor itself — the same contract as
    /// `TranscriptionService.PhaseHandler`.
    typealias ChatEventHandler = @Sendable (ChatStreamEvent) -> Void

    /// An answer plus the passages it was grounded on (retrieval mode). In
    /// full-context mode `citations` is empty — the view makes the `[mm:ss]`
    /// timestamps the model cites tappable instead.
    struct Answer: Sendable {
        var text: String
        var citations: [SemanticSearchService.Hit]
        /// Token usage the provider reported for the final generation call,
        /// when it exposed one. `nil` for the on-device provider (no usage
        /// concept) or a cloud response that didn't report it.
        var usage: TokenUsage?

        init(text: String, citations: [SemanticSearchService.Hit], usage: TokenUsage? = nil) {
            self.text = text
            self.citations = citations
            self.usage = usage
        }
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
    /// doesn't fit the model's `ContextBudget`),
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
        model: String,
        runID: OperationID = OperationID(),
        onEvent: @escaping ChatEventHandler = { _ in }
    ) async throws -> Answer {
        let startedAt = Date()
        let trimmed = try Self.requireQuestion(question, runID: runID)
        let llm = try resolveProvider(provider: provider, model: model, runID: runID, startedAt: startedAt)
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        var fullContextAnswer: Answer?
        if !transcript.isEmpty, budgetResolver(provider, model).fits(transcript) {
            let userPrompt = Self.fullContextPrompt(question: trimmed, transcript: transcript)
            do {
                let result = try await streamAnswer(
                    systemPrompt: Self.fullContextSystemPrompt,
                    messages: history + [ChatMessage(role: .user, content: userPrompt)],
                    llm: llm, onEvent: onEvent, runID: runID
                )
                fullContextAnswer = Answer(text: result.text, citations: [], usage: result.usage)
            } catch let error as AppError where error.isContextOverflow {
                // Rejected before anything streamed: the budget overestimated
                // this model's window, so answer from retrieval instead.
                AppLog.generation.atNotice.notice("chat: provider rejected full transcript as too long, using retrieval run=\(runID.value, privacy: .public)")
            }
        }
        let answer: Answer
        if let fullContextAnswer {
            answer = fullContextAnswer
        } else {
            answer = try await retrievedAnswer(
                question: trimmed, history: history, candidates: candidates, llm: llm, onEvent: onEvent, runID: runID
            )
        }
        ReliabilityLog.record(ReliabilityEvent(
            operationID: runID, operation: "meeting_chat",
            outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
        ))
        return answer
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
        model: String,
        runID: OperationID = OperationID(),
        onEvent: @escaping ChatEventHandler = { _ in }
    ) async throws -> Answer {
        let startedAt = Date()
        let trimmed = try Self.requireQuestion(question, runID: runID)
        let llm = try resolveProvider(provider: provider, model: model, runID: runID, startedAt: startedAt)
        let answer = try await libraryCombinedAnswer(
            question: trimmed, history: history, candidates: candidates,
            summaries: summariesByMeeting, articles: articlesByMeeting, llm: llm,
            budget: budgetResolver(provider, model), onEvent: onEvent, runID: runID
        )
        ReliabilityLog.record(ReliabilityEvent(
            operationID: runID, operation: "meeting_chat",
            outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
        ))
        return answer
    }

    /// Resolve the LLM provider, reporting a `"provider"`-stage failure (bad
    /// key, invalid URL, on-device model unavailable) the same way
    /// `DocumentGenerationService` reports its own provider-resolution step.
    private func resolveProvider(
        provider: AIProvider,
        model: String,
        runID: OperationID,
        startedAt: Date
    ) throws -> LLMProvider {
        do {
            return try providerResolver(provider, model)
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: "provider",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: Self.errorCode(error)
            ))
            throw error
        }
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
        llm: LLMProvider,
        onEvent: ChatEventHandler = { _ in }
    ) async throws -> [SemanticSearchService.Hit] {
        onEvent(.phase(.rewritingQuery))
        let expansion = try? await rewriteQuery(question, llm: llm)
        let denseText = expansion.map { "\(question)\n\($0)" } ?? question
        let lexicalQuery = expansion.map { "\(question) \($0)" } ?? question

        onEvent(.phase(.retrieving))
        var pool = try await searchService.hybridSearch(
            query: lexicalQuery, denseText: denseText, in: candidates, poolSize: poolSize
        )
        guard !pool.isEmpty else { return [] }
        if diversify {
            pool = SemanticSearchService.diversify(pool, maxPerMeeting: Self.maxHitsPerMeeting)
        }
        onEvent(.phase(.reranking))
        return (try? await rerank(question: question, pool: pool, limit: limit, llm: llm))
            ?? Array(pool.prefix(limit))
    }

    /// Runs the final, user-visible generation call, forwarding each text
    /// delta through `onEvent` as it arrives and returning the concatenated
    /// answer. Reports a `"answer"`-stage reliability event on cancellation or
    /// failure, the same way `DocumentGenerationService.requestText` reports
    /// its own per-call LLM failures (final success is reported once, by the
    /// entry point, not here). Not `private`: reused by
    /// `MeetingChatSynthesis.swift`.
    func streamAnswer(
        systemPrompt: String,
        messages: [ChatMessage],
        llm: LLMProvider,
        onEvent: @escaping ChatEventHandler,
        runID: OperationID
    ) async throws -> (text: String, usage: TokenUsage?) {
        onEvent(.phase(.answering))
        let startedAt = Date()
        let accumulator = StreamingAccumulator()
        let usage: TokenUsage?
        do {
            usage = try await llm.streamChat(systemPrompt: systemPrompt, messages: messages) { delta in
                guard !delta.isEmpty else { return }
                accumulator.append(delta)
                onEvent(.delta(delta))
            }
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: "answer",
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw CancellationError()
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: "answer",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: Self.errorCode(error)
            ))
            throw error
        }
        return (accumulator.value, usage)
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
        llm: LLMProvider,
        onEvent: @escaping ChatEventHandler = { _ in },
        runID: OperationID
    ) async throws -> Answer {
        let top = try await retrievePassages(
            question: question, candidates: candidates,
            poolSize: Self.poolSize(for: llm.provider), limit: Self.retrievalLimit(for: llm.provider), diversify: false, llm: llm,
            onEvent: onEvent
        )
        let userPrompt = Self.userPrompt(question: question, hits: top, scope: .singleMeeting, summaries: [:])
        let result = try await streamAnswer(
            systemPrompt: Self.systemPrompt(for: .singleMeeting),
            messages: history + [ChatMessage(role: .user, content: userPrompt)],
            llm: llm, onEvent: onEvent, runID: runID
        )
        return Answer(text: result.text, citations: top, usage: result.usage)
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

    // MARK: - Validation

    private static func requireQuestion(_ question: String, runID: OperationID) throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "meeting_chat", stage: "validation",
                outcome: .failed, code: "empty_question"
            ))
            throw AppError.apiError(
                statusCode: 0,
                message: NSLocalizedString("chat.error.empty_question", comment: "Empty chat question")
            )
        }
        return trimmed
    }

    /// Not `private`: reused by `MeetingChatSynthesis.swift`'s own error reporting.
    static func errorCode(_ error: Error) -> String {
        (error as? AppError)?.logCode ?? "unexpected"
    }
}
