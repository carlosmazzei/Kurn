//
//  LLMTranscriptCorrector.swift
//  Kurn
//
//  Opt-in LLM post-processing that corrects transcription errors (spelling,
//  punctuation, homophones, obvious ASR mistakes) on already-fused,
//  speaker-attributed segments. See `TranscriptCorrecting` in
//  `PipelineStages.swift` for the contract every conformer must honor: never
//  throw, always return `segments.count` segments in the same order, and only
//  ever touch `.text`.
//

import Foundation
import KurnCore

/// The `.none` correction engine: returns the input unchanged with no
/// allocation or network work, so leaving correction off costs nothing extra.
struct NoOpTranscriptCorrector: TranscriptCorrecting {
    func correct(
        segments: [TranscriptSegment],
        language: MeetingLanguage,
        provider: AIProvider,
        model: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> TranscriptCorrectionResult {
        TranscriptCorrectionResult(segments: segments, outcome: .skipped, reason: .notRequested)
    }
}

struct LLMTranscriptCorrector: TranscriptCorrecting {
    /// How the correction provider is built; tests pass a scripted one so the
    /// batch loop runs with no Keychain or network.
    private let resolveProvider: ProviderFactory.LLMResolver
    /// When set, the topic-aware mode (`CorrectionEngine.llmTopicAware`): a
    /// critic pass infers the meeting's topic and criticizes its vocabulary
    /// before any batch is corrected, and every batch carries its findings.
    /// `nil` is the original mode, guided only by the meeting's own recurring
    /// terms.
    private let topicAnalyzer: TranscriptTopicAnalyzer?

    init(
        topicAnalyzer: TranscriptTopicAnalyzer? = nil,
        resolveProvider: @escaping ProviderFactory.LLMResolver = ProviderFactory.liveLLM
    ) {
        self.topicAnalyzer = topicAnalyzer
        self.resolveProvider = resolveProvider
    }

    static let maxSegmentsPerBatch = 40
    static let maxBatchChars = 6_000
    /// Below this, a Whisper-reported confidence is treated as worth
    /// rechecking. `TranscriptQualityFilter` already dropped outright
    /// hallucinations (no_speech_prob>0.6 && avg_logprob<-1.0) before fusion,
    /// so what survives with a low-but-nonzero confidence is exactly this
    /// stage's target: marginal decodes, not invented ones.
    static let lowConfidenceThreshold: Float = 0.85

    private struct CorrectionRequestJSON: Encodable {
        struct Item: Encodable {
            let id: String
            let text: String
            /// Topic-aware mode only (nil fields are omitted from the JSON):
            /// the ASR's own confidence, so the model can tell a marginal
            /// decode from a confident one, and the neighbouring segments'
            /// text, read-only, so a word is judged by what was said around it.
            var confidence: Double?
            var before: String?
            var after: String?
        }
        /// Vocabulary hint built from this same meeting — see
        /// `MeetingVocabularyExtractor`. Sent once per request, not counted
        /// against `maxBatchChars` (a small fixed list, not per-segment
        /// content).
        let vocabulary: [String]
        /// Present only in the topic-aware mode; omitted from the JSON
        /// otherwise, so the original mode's request is unchanged.
        let topic: TopicJSON?
        let segments: [Item]
    }


    /// Whether `segment` is worth sending for correction: non-empty text, and
    /// either no confidence signal (Apple Speech, FluidAudio Parakeet — no
    /// per-token probability to read, so "can't rule it out" rather than
    /// "assume it's fine") or a Whisper confidence below the threshold.
    static func isEligible(_ segment: TranscriptSegment) -> Bool {
        guard hasText(segment) else { return false }
        guard let confidence = segment.confidence else { return true }
        return confidence < lowConfidenceThreshold
    }

    static func hasText(_ segment: TranscriptSegment) -> Bool {
        !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Greedily packs whole segments into batches bounded by both a character
    /// budget and a count cap, never splitting a segment — same shape as
    /// `SummaryService.packWholeItems`, applied to segments instead of
    /// markdown strings.
    static func batches(_ segments: [TranscriptSegment], maxChars: Int, maxCount: Int) -> [[TranscriptSegment]] {
        var result: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentChars = 0
        for segment in segments {
            let added = segment.text.count
            if !current.isEmpty && (current.count >= maxCount || currentChars + added > maxChars) {
                result.append(current)
                current = []
                currentChars = 0
            }
            current.append(segment)
            currentChars += added
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Pure. Reuses `ModelJSON`'s tolerant fence/prose-stripping (the same
    /// parser the auto-tagger uses). Any JSON failure yields an empty map
    /// so the caller fails open for that whole batch.
    static func parseCorrections(from reply: String) -> [UUID: String] {
        parsedCorrections(from: reply) ?? [:]
    }

    /// Pure. As `parseCorrections`, but `nil` for a reply that could not be
    /// parsed at all, which the empty map cannot express — a well-formed reply
    /// correcting nothing is a clean pass, an unparseable one is a failed
    /// batch, and the report has to tell them apart (H5 PR 11).
    static func parsedCorrections(from reply: String) -> [UUID: String]? {
        guard let data = try? ModelJSON.objectData(from: reply),
              let decoded = try? JSONDecoder().decode(CorrectionResponseJSON.self, from: data) else {
            return nil
        }
        var result: [UUID: String] = [:]
        for item in decoded.segments {
            guard let uuid = UUID(uuidString: item.id) else { continue }
            result[uuid] = item.text
        }
        return result
    }

    /// Pure. Applies `corrections` to `segments` by id lookup only — the
    /// returned array is always the same length, order, and every non-text
    /// field as the input. An id missing from `corrections`, an id the
    /// guardrail rejects, or an id in `corrections` that doesn't match any
    /// segment, all leave that segment's original text untouched. This is
    /// what makes "can't drop, merge, or reorder a segment" a structural
    /// guarantee rather than a prompt instruction.
    ///
    /// `faithfulTo`, when given (the topic-aware mode), additionally requires
    /// every word a correction introduces to be connected to what was said or
    /// to those grounded terms — see `CorrectionFaithfulness`.
    static func apply(
        corrections: [UUID: String],
        to segments: [TranscriptSegment],
        faithfulTo allowedTerms: [String]? = nil
    ) -> [TranscriptSegment] {
        var result = segments
        for index in segments.indices {
            let original = segments[index].text
            guard let corrected = corrections[segments[index].id],
                  TranscriptCorrectionGuardrail.accepts(original: original, corrected: corrected) else {
                continue
            }
            if let allowedTerms,
               !CorrectionFaithfulness.accepts(original: original, corrected: corrected, allowedTerms: allowedTerms) {
                continue
            }
            result[index].text = corrected
        }
        return result
    }

    func correct(
        segments: [TranscriptSegment],
        language: MeetingLanguage,
        provider: AIProvider,
        model: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> TranscriptCorrectionResult {
        let lowConfidence = segments.filter(Self.isEligible)
        // The topic-aware mode can also send a confident segment the critic
        // flags, so it only needs some text to read; the original mode needs
        // a low-confidence segment.
        let hasWork = topicAnalyzer == nil ? !lowConfidence.isEmpty : segments.contains(where: Self.hasText)
        guard hasWork else {
            return TranscriptCorrectionResult(segments: segments, outcome: .skipped, reason: .noInput)
        }

        let meetingTerms = MeetingVocabularyExtractor.extract(from: segments)

        let llm: LLMProvider
        do {
            llm = try resolveProvider(provider, model)
        } catch {
            AppLog.transcription.atNotice.notice("correct: no usable provider (code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)); skipping correction")
            return TranscriptCorrectionResult(
                segments: segments,
                outcome: .degraded,
                reason: .providerUnavailable
            )
        }

        // The critic reads the whole transcript, confident segments included —
        // they are the best evidence of what the meeting is about.
        let profile = await topicAnalyzer?.analyze(
            segments: segments, meetingTerms: meetingTerms, language: language, llm: llm
        )
        let vocabulary = CorrectionVocabulary.merge(meetingTerms: meetingTerms, profile: profile)
        let critiqueFailed = topicAnalyzer != nil && profile == nil
        let candidates = profile.map { Self.candidates(in: segments, flaggedBy: $0) } ?? lowConfidence
        guard !candidates.isEmpty else {
            return critiqueFailed
                ? TranscriptCorrectionResult(segments: segments, outcome: .degraded, reason: .topicAnalysisFailed)
                : TranscriptCorrectionResult(segments: segments, outcome: .skipped, reason: .noInput)
        }
        let context = profile == nil ? [:] : Self.neighbourContext(of: segments)
        let allowedTerms = profile.map { Self.allowedTerms(vocabulary: vocabulary, profile: $0) }

        var result = segments
        var done = 0
        // A batch that failed still leaves the original text in place, which is
        // also what a batch that found nothing to fix leaves — so the failure
        // is counted here rather than inferred from the segments afterwards.
        var failedBatches = 0
        var batchCount = 0
        for batch in Self.batches(candidates, maxChars: Self.maxBatchChars, maxCount: Self.maxSegmentsPerBatch) {
            guard !Task.isCancelled else { break }
            batchCount += 1
            let outcome = await requestBatch(
                for: batch, vocabulary: vocabulary, profile: profile, context: context, language: language, llm: llm
            )
            if outcome.failed { failedBatches += 1 }
            result = Self.apply(corrections: outcome.corrections, to: result, faithfulTo: allowedTerms)
            done += batch.count
            onProgress(Double(done) / Double(candidates.count))
        }
        // Every batch failing means the stage produced nothing; some of them
        // failing means it ran but covered only part of the transcript.
        if batchCount > 0 && failedBatches == batchCount {
            return TranscriptCorrectionResult(segments: result, outcome: .failed, reason: .engineFailed)
        }
        if failedBatches > 0 {
            return TranscriptCorrectionResult(segments: result, outcome: .degraded, reason: .engineFailed)
        }
        // Corrected with the meeting's own vocabulary only: useful, but not
        // the topic-aware pass that was asked for (H-I4).
        if critiqueFailed && !Task.isCancelled {
            return TranscriptCorrectionResult(segments: result, outcome: .degraded, reason: .topicAnalysisFailed)
        }
        return TranscriptCorrectionResult(segments: result)
    }

    /// One batch's corrections and whether producing them failed. Both are
    /// needed: a failed batch and a batch the model had nothing to fix for
    /// both yield no corrections.
    struct BatchOutcome: Sendable {
        var corrections: [UUID: String]
        var failed: Bool
    }

    /// Not `private` so tests can call it directly with an injected
    /// `LLMProvider`, bypassing `ProviderFactory`/Keychain.
    func requestCorrections(
        for batch: [TranscriptSegment],
        vocabulary: [String],
        language: MeetingLanguage,
        llm: LLMProvider
    ) async -> [UUID: String] {
        await requestBatch(for: batch, vocabulary: vocabulary, language: language, llm: llm).corrections
    }

    func requestBatch(
        for batch: [TranscriptSegment],
        vocabulary: [String],
        profile: MeetingTopicProfile? = nil,
        context: [UUID: NeighbourContext] = [:],
        language: MeetingLanguage,
        llm: LLMProvider
    ) async -> BatchOutcome {
        let topicAware = profile != nil
        let payload = CorrectionRequestJSON(
            vocabulary: vocabulary,
            topic: profile.map(TopicJSON.init),
            segments: batch.map { segment in
                CorrectionRequestJSON.Item(
                    id: segment.id.uuidString,
                    text: segment.text,
                    confidence: topicAware ? segment.confidence.map(Self.roundedConfidence) : nil,
                    before: context[segment.id]?.before,
                    after: context[segment.id]?.after
                )
            }
        )
        guard let bodyData = try? JSONEncoder().encode(payload),
              let bodyText = String(data: bodyData, encoding: .utf8) else {
            return BatchOutcome(corrections: [:], failed: true)
        }
        do {
            let reply = try await llm.chat(
                systemPrompt: Self.systemPrompt(language: language, topicAware: topicAware),
                messages: [ChatMessage(role: .user, content: "Segments JSON:\n\(bodyText)")],
                options: .document
            )
            guard let corrections = Self.parsedCorrections(from: reply) else {
                AppLog.transcription.atNotice.notice("correct: batch of \(batch.count, privacy: .public) segment(s) returned an unparseable reply, keeping originals")
                return BatchOutcome(corrections: [:], failed: true)
            }
            return BatchOutcome(corrections: corrections, failed: false)
        } catch {
            AppLog.transcription.atNotice.notice("correct: batch of \(batch.count, privacy: .public) segment(s) failed, keeping originals code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return BatchOutcome(corrections: [:], failed: true)
        }
    }

    static func systemPrompt(language: MeetingLanguage, topicAware: Bool = false) -> String {
        topicAware ? basePrompt(language: language) + "\n\n" + topicGuidance : basePrompt(language: language)
    }

    private static func basePrompt(language: MeetingLanguage) -> String {
        """
        You are a meticulous transcription proofreader correcting automatic speech \
        recognition (ASR) output. You will receive a JSON object with a "vocabulary" \
        array (names, acronyms, and terms already heard elsewhere in this same \
        meeting, spelled as shown) and a "segments" array; each segment item has an \
        "id" and the ASR "text" for one speaker turn. The meeting's primary language \
        is \(language.displayName).

        For each segment, fix ONLY:
        - Spelling mistakes and obviously misheard/garbled words, including homophones \
        — prefer a "vocabulary" spelling when a word sounds like one of those terms.
        - Missing, wrong, or duplicated punctuation and capitalization.
        - Words incorrectly merged together or split apart.

        Never do any of the following:
        - Do not add, remove, or reorder words beyond fixing one of the errors above.
        - Do not paraphrase, summarize, or otherwise change wording, tone, or meaning.
        - Do not invent names, numbers, dates, or any fact not already present, \
        including ones not in "vocabulary".
        - Do not translate — keep every segment in the language it is already in.
        - Do not merge, split, drop, reorder, or add segments. Every input "id" must \
        appear exactly once in your output.
        - If a segment already has no error, return its "text" byte-for-byte unchanged.

        Output ONLY valid JSON with this exact shape and nothing else — no prose, no \
        markdown fences:
        {"segments":[{"id":"<same id as input>","text":"<corrected text>"}]}
        """
    }
}
