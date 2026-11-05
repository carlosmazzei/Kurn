//
//  LLMTranscriptCorrector+Context.swift
//  Kurn
//
//  How the correction loop combines the ASR's confidence, the critic's topic
//  profile (`TranscriptTopicAnalyzer`) and the surrounding speech, and how it
//  keeps a correction faithful to what was said:
//
//  - which segments are sent: low or unknown ASR confidence (as before) **or**
//    a segment containing a form the critic flagged — a confident decode of
//    the wrong word is exactly what confidence alone cannot catch;
//  - what each is sent with: its confidence and its neighbours' text, so the
//    model reads a word in the conversation it was said in;
//  - what a correction may introduce: only words connected to what was said
//    or grounded in this meeting (`CorrectionFaithfulness`).
//

import Foundation
import KurnCore

extension LLMTranscriptCorrector {
    /// The text either side of a segment, sent read-only.
    struct NeighbourContext: Sendable, Equatable {
        var before: String?
        var after: String?
    }

    /// Characters of neighbouring text sent per side. Enough for the end of
    /// the previous sentence and the start of the next, small enough that a
    /// 40-segment batch does not double in size.
    static let neighbourContextCharacters = 160

    struct TopicJSON: Encodable {
        struct Finding: Encodable { let heard: String; let intended: String }
        let summary: String
        let domain: String
        let likelyMishearings: [Finding]

        init(_ profile: MeetingTopicProfile) {
            summary = profile.topic
            domain = profile.domain
            likelyMishearings = profile.mishearings.map { Finding(heard: $0.heard, intended: $0.intended) }
        }
    }

    /// Pure. The segments sent for correction, in transcript order: every
    /// segment `isEligible` (low or unknown confidence), plus any segment —
    /// however confident — that contains one of `profile`'s flagged forms.
    /// Without a profile it is exactly the low-confidence set.
    static func candidates(in segments: [TranscriptSegment], flaggedBy profile: MeetingTopicProfile?) -> [TranscriptSegment] {
        let flagged = (profile?.mishearings ?? []).map { $0.heard.lowercased() }
        return segments.filter { segment in
            guard hasText(segment) else { return false }
            if isEligible(segment) { return true }
            let text = segment.text.lowercased()
            return flagged.contains { text.contains($0) }
        }
    }

    /// Pure. Each segment's neighbours' text, the previous one's tail and the
    /// next one's head, trimmed to `neighbourContextCharacters`. Neighbours are
    /// taken from the whole transcript, not the batch, so the first segment
    /// of a batch still sees what came before it.
    static func neighbourContext(of segments: [TranscriptSegment]) -> [UUID: NeighbourContext] {
        let limit = neighbourContextCharacters
        var result: [UUID: NeighbourContext] = [:]
        for index in segments.indices {
            let before = index > segments.startIndex ? segments[index - 1].text : nil
            let after = index < segments.index(before: segments.endIndex) ? segments[index + 1].text : nil
            result[segments[index].id] = NeighbourContext(
                before: before.flatMap { tail($0, limit: limit) },
                after: after.flatMap { head($0, limit: limit) }
            )
        }
        return result
    }

    /// Pure. The terms a correction may introduce without them sounding like
    /// anything the ASR wrote: the merged vocabulary and the intended side of
    /// every grounded finding.
    static func allowedTerms(vocabulary: [String], profile: MeetingTopicProfile?) -> [String] {
        vocabulary + (profile?.mishearings ?? []).map(\.intended)
    }

    /// Confidence rounded to two decimals — precision beyond that is noise to
    /// the model and only makes the request longer.
    static func roundedConfidence(_ value: Float) -> Double {
        (Double(value) * 100).rounded() / 100
    }

    private static func head(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }

    private static func tail(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : "…" + String(trimmed.suffix(limit))
    }

    /// Always part of the system prompt: what the per-segment context fields
    /// mean, and the faithfulness rule `CorrectionFaithfulness` enforces in
    /// code — so a correction the prompt fails to restrain is still rejected.
    static let contextGuidance = """
        Segments may carry "confidence" (the ASR's own, 0–1: the lower it is, the \
        more likely the text is misheard; a high value means change it only for a \
        clear error) and "before"/"after" (the neighbouring speech, for context only \
        — never correct or return it). Read each segment in that context and stay \
        faithful to what was said: every word you change must sound like what the \
        ASR wrote. Never add a word that was not spoken — corrections that do are \
        discarded.
        """

    /// Appended when the critic produced a profile. Its findings are a
    /// reviewer's hypotheses, so the prompt asks for them to be applied only
    /// where the segment actually sounds like them.
    static let topicGuidance = """
        The request also has a "topic" object, written by a reviewer who read the \
        whole meeting: "summary" says what it is about, "domain" the field it \
        belongs to, and "likelyMishearings" lists places where the reviewer thinks \
        the ASR wrote something that sounds like a term of this topic but makes no \
        sense in it ("heard" → "intended"); "vocabulary" also includes the terms \
        this topic makes likely. Use the topic to read ambiguous words the way a \
        participant in this meeting would. Apply a finding only where a segment \
        contains its "heard" form (or something that sounds the same) and the \
        intended term fits the sentence; the reviewer can be wrong, and a word \
        that is plausible as written must stay as written.
        """
}
