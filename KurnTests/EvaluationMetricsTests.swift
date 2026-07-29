//
//  EvaluationMetricsTests.swift
//  KurnTests
//
//  The measuring instruments, measured.
//
//  Every accuracy claim made about this pipeline so far has been inference from
//  the literature rather than measurement — "Whisper's own thresholds", "the
//  standard far-field front end" — because there was nothing to measure with.
//  These are that instrument, so they are held to hand-computable cases: if the
//  ruler is wrong, every number taken with it is wrong in a way that looks
//  authoritative.
//

import Foundation
import Testing

struct EvaluationMetricsTests {

    // MARK: - Normalization

    @Test func normalizationIgnoresCasePunctuationAndSpacing() {
        #expect(
            TextNormalizer.tokens("Vamos começar, então!")
                == TextNormalizer.tokens("  vamos   começar então  ")
        )
    }

    /// Accents are meaning in six of the seven languages this app ships, so
    /// compatibility normalization must not strip them — only recompose them.
    @Test func normalizationKeepsAccents() {
        #expect(TextNormalizer.tokens("orçamento") == ["orçamento"])
        #expect(TextNormalizer.tokens("café") != TextNormalizer.tokens("cafe"))
    }

    @Test func unsegmentedScriptIsComparedByCharacter() {
        #expect(TextNormalizer.tokens("谢谢观看") == ["谢", "谢", "观", "看"])
        // Mixed text keeps Latin words whole.
        #expect(TextNormalizer.tokens("ok 谢谢") == ["ok", "谢", "谢"])
    }

    // MARK: - WER

    @Test func identicalTranscriptsScoreZero() {
        let result = WordErrorRate.compare(
            reference: "vamos revisar o orçamento",
            hypothesis: "Vamos revisar o orçamento."
        )
        #expect(result.rate == 0)
        #expect(result.errors == 0)
    }

    /// The breakdown is the point: three failures with three different fixes.
    @Test func separatesSubstitutionsInsertionsAndDeletions() {
        // reference: a b c d
        // hypothesis: a x c d e   → one substitution (b→x), one insertion (e)
        let substituted = WordErrorRate.compare(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c", "d", "e"])
        #expect(substituted.substitutions == 1)
        #expect(substituted.insertions == 1)
        #expect(substituted.deletions == 0)
        #expect(substituted.referenceCount == 4)
        #expect(abs(substituted.rate - 0.5) < 1e-9)

        let dropped = WordErrorRate.compare(reference: ["a", "b", "c", "d"], hypothesis: ["a", "d"])
        #expect(dropped.deletions == 2)
        #expect(dropped.substitutions == 0)
        #expect(dropped.insertions == 0)
    }

    /// A hallucinated run over silence: nothing was said, everything was
    /// transcribed. Worse than saying nothing, and the rate says so.
    @Test func inventedTextOverSilenceExceedsOneHundredPercent() {
        let result = WordErrorRate.compare(reference: ["obrigado"], hypothesis: ["thank", "you", "for", "watching"])
        #expect(result.insertions == 3)
        #expect(result.substitutions == 1)
        #expect(result.rate > 1)
    }

    @Test func emptySidesDegradeSensibly() {
        #expect(WordErrorRate.compare(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.compare(reference: "", hypothesis: "olá").rate == 1)
        #expect(WordErrorRate.compare(reference: "olá mundo", hypothesis: "").deletions == 2)
    }

    // MARK: - DER

    private func segment(_ label: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizationErrorRate.Segment {
        DiarizationErrorRate.Segment(label: label, start: start, end: end)
    }

    /// The property that makes DER usable at all: a diarizer's own label names
    /// carry no meaning, so a perfect result under different names must score 0.
    @Test func relabellingAPerfectResultIsNotAnError() {
        let reference = [segment("Ana", 0, 10), segment("Bruno", 10, 20)]
        let hypothesis = [segment("Speaker 2", 0, 10), segment("Speaker 1", 10, 20)]

        let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(result.rate == 0)
        #expect(result.mapping["Ana"] == "Speaker 2")
        #expect(result.mapping["Bruno"] == "Speaker 1")
    }

    /// This app's actual failure mode: the clustering step collapses and the
    /// whole meeting comes back as one speaker. Half the speech is then
    /// attributed to the wrong person — and none of it is missed, which is
    /// exactly why confusion is reported apart from missed time.
    @Test func collapsingToOneSpeakerScoresAsConfusionNotMissedTime() {
        let reference = [segment("Ana", 0, 10), segment("Bruno", 10, 20)]
        let hypothesis = [segment("Speaker 1", 0, 20)]

        let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(abs(result.rate - 0.5) < 1e-9)
        #expect(result.confusion == 10)
        #expect(result.missed == 0)
        #expect(result.falseAlarm == 0)
    }

    @Test func silenceHeardAsSpeechIsFalseAlarm() {
        let reference = [segment("Ana", 0, 10)]
        let hypothesis = [segment("Speaker 1", 0, 15)]

        let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(result.falseAlarm == 5)
        #expect(result.missed == 0)
        #expect(abs(result.rate - 0.5) < 1e-9)
    }

    @Test func speechHeardAsSilenceIsMissedTime() {
        let reference = [segment("Ana", 0, 10)]
        let hypothesis = [segment("Speaker 1", 0, 6)]

        let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(result.missed == 4)
        #expect(result.falseAlarm == 0)
    }

    /// Without a collar, DER mostly measures disagreement about the instant a
    /// word ended — which neither annotator nor diarizer can place exactly.
    @Test func theCollarForgivesABoundaryNudge() {
        let reference = [segment("Ana", 0, 10), segment("Bruno", 10, 20)]
        // The handover is heard 0.2 s late, well inside the 0.25 s collar.
        let hypothesis = [segment("S1", 0, 10.2), segment("S2", 10.2, 20)]

        let scored = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis)
        #expect(scored.rate == 0)

        let unforgiving = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(unforgiving.rate > 0)
    }

    @Test func overlappingReferenceSpeechCountsTwice() {
        // Both talking 5…10. A single-label hypothesis can attribute only one of
        // them, so the other 5 s is missed by construction — which is the whole
        // argument for overlap-aware diarization, quantified.
        let reference = [segment("Ana", 0, 10), segment("Bruno", 5, 15)]
        let hypothesis = [segment("S1", 0, 10), segment("S2", 10, 15)]

        let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(result.referenceSpeech == 20)
        #expect(result.missed == 5)
    }

    @Test func anEmptyHypothesisMissesEverything() {
        let result = DiarizationErrorRate.compare(
            reference: [segment("Ana", 0, 10)],
            hypothesis: [],
            collar: 0
        )
        #expect(result.rate == 1)
        #expect(result.missed == 10)
    }

    // MARK: - RTTM

    @Test func parsesRTTMTurns() {
        let text = """
        ; a comment line the tools emit
        SPEAKER meeting1 1 0.000 10.500 <NA> <NA> Ana <NA> <NA>
        SPEAKER meeting1 1 10.500 4.250 <NA> <NA> Bruno <NA> <NA>
        SPEAKER meeting1 1 bad 4.250 <NA> <NA> Bruno <NA> <NA>
        """
        let segments = RTTM.parse(text)
        #expect(segments.count == 2)
        #expect(segments.first?.label == "Ana")
        #expect(segments.first?.end == 10.5)
        #expect(segments.last?.start == 10.5)
        #expect(segments.last?.duration == 4.25)
    }

    @Test func rttmRoundTrips() {
        let segments = [
            DiarizationErrorRate.Segment(label: "Ana", start: 0, end: 10.5),
            DiarizationErrorRate.Segment(label: "Bruno", start: 10.5, end: 14.75)
        ]
        #expect(RTTM.parse(RTTM.format(segments, fileID: "meeting1")) == segments)
    }
}
