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
    ) async -> [TranscriptSegment] {
        segments
    }
}

struct LLMTranscriptCorrector: TranscriptCorrecting {
    static let maxSegmentsPerBatch = 40
    static let maxBatchChars = 6_000
    /// Below this, a Whisper-reported confidence is treated as worth
    /// rechecking. `TranscriptQualityFilter` already dropped outright
    /// hallucinations (no_speech_prob>0.6 && avg_logprob<-1.0) before fusion,
    /// so what survives with a low-but-nonzero confidence is exactly this
    /// stage's target: marginal decodes, not invented ones.
    static let lowConfidenceThreshold: Float = 0.85

    private struct CorrectionRequestJSON: Encodable {
        struct Item: Encodable { let id: String; let text: String }
        /// Vocabulary hint built from this same meeting — see
        /// `MeetingVocabularyExtractor`. Sent once per request, not counted
        /// against `maxBatchChars` (a small fixed list, not per-segment
        /// content).
        let vocabulary: [String]
        let segments: [Item]
    }

    private struct CorrectionResponseJSON: Decodable {
        struct Item: Decodable { let id: String; let text: String }
        let segments: [Item]
    }

    /// Whether `segment` is worth sending for correction: non-empty text, and
    /// either no confidence signal (Apple Speech, FluidAudio Parakeet — no
    /// per-token probability to read, so "can't rule it out" rather than
    /// "assume it's fine") or a Whisper confidence below the threshold.
    static func isEligible(_ segment: TranscriptSegment) -> Bool {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let confidence = segment.confidence else { return true }
        return confidence < lowConfidenceThreshold
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
    /// parser `SummaryJSON.parse` uses). Any JSON failure yields an empty map
    /// so the caller fails open for that whole batch.
    static func parseCorrections(from reply: String) -> [UUID: String] {
        guard let data = try? ModelJSON.objectData(from: reply),
              let decoded = try? JSONDecoder().decode(CorrectionResponseJSON.self, from: data) else {
            return [:]
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
    static func apply(corrections: [UUID: String], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result = segments
        for index in segments.indices {
            guard let corrected = corrections[segments[index].id],
                  TranscriptCorrectionGuardrail.accepts(original: segments[index].text, corrected: corrected) else {
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
    ) async -> [TranscriptSegment] {
        let candidates = segments.filter(Self.isEligible)
        guard !candidates.isEmpty else { return segments }

        let vocabulary = MeetingVocabularyExtractor.extract(from: segments)

        let llm: LLMProvider
        do {
            llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        } catch {
            AppLog.transcription.atNotice.notice("correct: no usable provider (\(error.localizedDescription, privacy: .public)); skipping correction")
            return segments
        }

        var result = segments
        var done = 0
        for batch in Self.batches(candidates, maxChars: Self.maxBatchChars, maxCount: Self.maxSegmentsPerBatch) {
            guard !Task.isCancelled else { break }
            let corrections = await requestCorrections(for: batch, vocabulary: vocabulary, language: language, llm: llm)
            result = Self.apply(corrections: corrections, to: result)
            done += batch.count
            onProgress(Double(done) / Double(candidates.count))
        }
        return result
    }

    /// Not `private` so tests can call it directly with an injected
    /// `LLMProvider`, bypassing `ProviderFactory`/Keychain.
    func requestCorrections(
        for batch: [TranscriptSegment],
        vocabulary: [String],
        language: MeetingLanguage,
        llm: LLMProvider
    ) async -> [UUID: String] {
        let payload = CorrectionRequestJSON(
            vocabulary: vocabulary,
            segments: batch.map { .init(id: $0.id.uuidString, text: $0.text) }
        )
        guard let bodyData = try? JSONEncoder().encode(payload),
              let bodyText = String(data: bodyData, encoding: .utf8) else {
            return [:]
        }
        do {
            let reply = try await llm.chat(
                systemPrompt: Self.systemPrompt(language: language),
                messages: [ChatMessage(role: .user, content: "Segments JSON:\n\(bodyText)")],
                options: .document
            )
            return Self.parseCorrections(from: reply)
        } catch {
            AppLog.transcription.atNotice.notice("correct: batch of \(batch.count, privacy: .public) segment(s) failed, keeping originals: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    static func systemPrompt(language: MeetingLanguage) -> String {
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
