//
//  TranscriptQualityFilterTests.swift
//  KurnTests
//
//  The rules that decide whether Whisper actually heard a segment.
//
//  Both directions are asserted deliberately. A filter that drops everything
//  suspicious passes a "catches hallucinations" test and destroys real
//  transcripts, so roughly half of these assert that ordinary speech — quiet,
//  emphatic, or merely repetitive — survives.
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptQualityFilterTests {

    // MARK: - Silence

    /// Whisper's own rule, and the reason it is a conjunction: a high no-speech
    /// probability is only evidence when the decode was also unconfident.
    @Test func dropsAnUnconfidentDecodeOverSilence() {
        let quality = SpanQuality(averageLogProb: -1.4, noSpeechProb: 0.9, compressionRatio: 1.5)
        #expect(TranscriptQualityFilter.rejection(text: "Thank you.", quality: quality) == .silence)
    }

    @Test func keepsAConfidentDecodeDespiteHighNoSpeechProbability() {
        let quality = SpanQuality(averageLogProb: -0.2, noSpeechProb: 0.9, compressionRatio: 1.5)
        #expect(TranscriptQualityFilter.rejection(text: "Thank you.", quality: quality) == nil)
    }

    /// A quiet talker decodes badly without the model calling it silence. Dropping
    /// on log-probability alone is what turns a soft-spoken participant into a gap.
    @Test func keepsAnUnconfidentDecodeThatTheModelCallsSpeech() {
        let quality = SpanQuality(averageLogProb: -1.8, noSpeechProb: 0.05, compressionRatio: 1.5)
        #expect(TranscriptQualityFilter.rejection(text: "…orçamento do trimestre.", quality: quality) == nil)
    }

    /// Vendors that omit the fields must not have absence read as guilt.
    @Test func missingSignalsAreNotEvidence() {
        #expect(TranscriptQualityFilter.rejection(text: "Bom dia a todos.", quality: .unknown) == nil)
        #expect(
            TranscriptQualityFilter.rejection(
                text: "Bom dia a todos.",
                quality: SpanQuality(averageLogProb: nil, noSpeechProb: 0.95, compressionRatio: nil)
            ) == nil
        )
    }

    // MARK: - Compression

    @Test func dropsOverCompressibleText() {
        let quality = SpanQuality(averageLogProb: -0.3, noSpeechProb: 0.1, compressionRatio: 3.0)
        #expect(TranscriptQualityFilter.rejection(text: "Sim. Sim. Sim.", quality: quality) == .compression)
    }

    @Test func keepsOrdinaryProseCompressibility() {
        let quality = SpanQuality(averageLogProb: -0.3, noSpeechProb: 0.1, compressionRatio: 2.0)
        #expect(TranscriptQualityFilter.rejection(text: "Vamos revisar o orçamento.", quality: quality) == nil)
    }

    // MARK: - Repetition

    @Test func detectsASingleWordLoop() {
        #expect(TranscriptQualityFilter.isRepetitionLoop("ok ok ok ok ok ok"))
        #expect(TranscriptQualityFilter.isRepetitionLoop("Ok, ok, ok, ok, ok, ok, ok."))
    }

    @Test func detectsARepeatedPhrase() {
        let text = "Legendas pela comunidade Amara.org "
            + "Legendas pela comunidade Amara.org "
            + "Legendas pela comunidade Amara.org"
        #expect(TranscriptQualityFilter.isRepetitionLoop(text))
    }

    /// The loop in a script written without spaces, where splitting on whitespace
    /// would find a single token and nothing to compare.
    @Test func detectsALoopInAnUnsegmentedScript() {
        #expect(TranscriptQualityFilter.isRepetitionLoop("谢谢观看谢谢观看谢谢观看谢谢观看"))
    }

    @Test func emphaticRepetitionIsNotALoop() {
        #expect(!TranscriptQualityFilter.isRepetitionLoop("não não"))
        #expect(!TranscriptQualityFilter.isRepetitionLoop("no, no, no, that's not what I meant"))
        #expect(!TranscriptQualityFilter.isRepetitionLoop("muito muito muito bom mesmo"))
    }

    @Test func ordinarySpeechIsNotALoop() {
        #expect(!TranscriptQualityFilter.isRepetitionLoop(
            "Vamos começar a reunião de hoje falando sobre o orçamento do próximo trimestre."
        ))
        // Parallel structure repeats the opening words without cycling.
        #expect(!TranscriptQualityFilter.isRepetitionLoop("eu acho que sim, eu acho que não"))
        #expect(!TranscriptQualityFilter.isRepetitionLoop(""))
    }

    /// The coverage floor: a stutter inside a good sentence must not take the
    /// sentence with it.
    @Test func aLoopMustDominateTheSegmentToCountAsOne() {
        let text = "então eu eu eu eu eu eu queria propor que a gente adiasse a decisão "
            + "sobre o contrato até a próxima reunião do comitê"
        #expect(!TranscriptQualityFilter.isRepetitionLoop(text))
    }

    // MARK: - Filtering

    @Test func keepsSurvivorsInOrderAndStampsConfidence() {
        let good = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "Primeiro ponto da pauta.", start: 0, end: 2, confidence: nil),
            quality: SpanQuality(averageLogProb: -0.2, noSpeechProb: 0.05, compressionRatio: 1.4)
        )
        let hallucinated = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "Thank you for watching.", start: 2, end: 4, confidence: nil),
            quality: SpanQuality(averageLogProb: -1.6, noSpeechProb: 0.95, compressionRatio: 1.2)
        )
        let looped = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "ok ok ok ok ok ok ok", start: 4, end: 6, confidence: nil),
            quality: .unknown
        )
        let last = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "Segundo ponto.", start: 6, end: 8, confidence: nil),
            quality: .unknown
        )

        let kept = TranscriptQualityFilter.keeping([good, hallucinated, looped, last], engine: "test")

        #expect(kept.map(\.text) == ["Primeiro ponto da pauta.", "Segundo ponto."])
        // `exp(-0.2)`: the mean per-token probability the decoder reported.
        #expect((kept.first?.confidence ?? 0) > 0.81)
        #expect((kept.first?.confidence ?? 0) < 0.82)
        // Nothing to derive a confidence from stays honest about it.
        #expect(kept.last?.confidence == nil)
    }

    @Test func confidenceIsClampedToAProbability() {
        #expect(SpanQuality(averageLogProb: 0.5).confidence == 1)
        #expect(SpanQuality(averageLogProb: -.infinity).confidence == nil)
        #expect(SpanQuality.unknown.confidence == nil)
    }
}
