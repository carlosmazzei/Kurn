//
//  TranscriptTopicAnalyzer.swift
//  Kurn
//
//  The first step of topic-aware correction (`CorrectionEngine.llmTopicAware`):
//  an LLM acting as a critic reads a sample of the ASR result, infers what the
//  meeting is about, and then criticizes the transcript's vocabulary against
//  that topic — the words that make no sense for the subject, paired with the
//  term most likely said. `LLMTranscriptCorrector` sends that profile (topic,
//  domain terms and the critique's findings) with every correction batch, so
//  each batch is read with the whole meeting's subject in mind rather than 40
//  segments in isolation. Parsing, bounding and grounding the reply is
//  KurnCore's `MeetingTopicProfile`: a finding whose "heard" form is not in
//  the transcript is discarded as invented.
//

import Foundation
import KurnCore

struct TranscriptTopicAnalyzer: Sendable {
    var maxExcerptCharacters = TopicAnalysisExcerpt.defaultMaxCharacters

    /// Never throws: a failed call, an unparseable reply or a reply with
    /// nothing usable is `nil`, and correction carries on with the meeting's
    /// own vocabulary alone. The returned profile is already grounded in
    /// `segments`, so no mishearing it carries is absent from the transcript.
    func analyze(
        segments: [TranscriptSegment],
        meetingTerms: [String],
        language: MeetingLanguage,
        llm: LLMProvider
    ) async -> MeetingTopicProfile? {
        let excerpt = TopicAnalysisExcerpt.build(from: segments, maxCharacters: maxExcerptCharacters)
        guard !excerpt.isEmpty else { return nil }
        do {
            let reply = try await llm.chat(
                systemPrompt: Self.systemPrompt(language: language),
                messages: [ChatMessage(role: .user, content: Self.userPrompt(excerpt: excerpt, meetingTerms: meetingTerms))],
                options: .document
            )
            guard let profile = MeetingTopicProfile.parse(reply)?.grounded(in: segments), !profile.isEmpty else {
                AppLog.transcription.atNotice.notice("topic analysis: reply carried no usable profile")
                return nil
            }
            let terms = profile.keyTerms.count, findings = profile.mishearings.count
            AppLog.transcription.atInfo.info("topic analysis: \(terms, privacy: .public) term(s), \(findings, privacy: .public) finding(s)")
            return profile
        } catch {
            AppLog.transcription.atNotice.notice(
                "topic analysis failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    static func userPrompt(excerpt: String, meetingTerms: [String]) -> String {
        let terms = meetingTerms.isEmpty ? "(none)" : meetingTerms.joined(separator: ", ")
        return """
        Terms that recur in this transcript: \(terms)

        Transcript excerpt (ASR output, "…" marks skipped parts):
        \(excerpt)
        """
    }

    static func systemPrompt(language: MeetingLanguage) -> String {
        """
        You are a critical reviewer of automatic speech recognition (ASR) \
        transcripts of meetings. The meeting's primary language is \
        \(language.displayName). Read the excerpt, work out what the meeting is \
        about, and then criticize its vocabulary against that topic: which words \
        do not belong in a conversation on this subject, and what was most likely \
        said instead? Report:

        - "topic": one sentence saying what the meeting is about.
        - "domain": the field it belongs to, in a few words (for example \
        "software engineering", "cardiology", "corporate finance").
        - "key_terms": up to 40 names, products, technologies, acronyms and \
        jargon this topic makes likely, spelled exactly as they should be \
        written — including the correct spelling of terms the ASR garbled.
        - "likely_mishearings": up to 20 findings of your critique — places \
        where the ASR wrote something that sounds like a term of this topic but \
        makes no sense in it (a homophone, a word split in two, a name \
        rendered as common words). "heard" must be copied exactly as it \
        appears in the excerpt; "intended" is the term most likely said.

        Rules:
        - Only report what the excerpt supports. A word that is unusual but \
        plausible for the topic is not a mishearing. Do not guess names of \
        people who are never mentioned, and do not list generic everyday words.
        - Keep every term in the language and spelling it is used in; do not \
        translate.
        - When unsure, leave an item out — an empty list is a valid answer.

        Output ONLY valid JSON with this exact shape and nothing else — no \
        prose, no markdown fences:
        {"topic":"...","domain":"...","key_terms":["..."],\
        "likely_mishearings":[{"heard":"...","intended":"..."}]}
        """
    }
}
