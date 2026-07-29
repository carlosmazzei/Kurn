//
//  WordTimestampTests.swift
//  KurnTests
//
//  Word-level timings, and what happens when they are absent or wrong.
//
//  The absence case carries most of the weight. Three engines report timings
//  through three different mechanisms, none of which can be exercised here — no
//  network, no whisper.cpp linked into the test target, no Speech locale asset.
//  What *is* testable is the contract around them: a missing timing degrades to
//  today's behaviour, and a timing that contradicts the segment it belongs to is
//  refused rather than trusted.
//

import Foundation
import Testing
@testable import Kurn

struct WordTimestampTests {

    // MARK: - Apple Speech result assembly

    @Test func wordsBecomeOneSpanEach() {
        let spans = OnDeviceTranscriber.spans(
            words: [
                TimedWord(text: "vamos", start: 10, end: 10.4),
                TimedWord(text: "começar", start: 10.4, end: 11.0)
            ],
            text: "vamos começar",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(spans.map(\.text) == ["vamos", "começar"])
        #expect(spans.first?.start == 10)
        #expect(spans.last?.end == 11)
    }

    @Test func noWordsFallsBackToTheResultSpan() {
        let spans = OnDeviceTranscriber.spans(
            words: [],
            text: "vamos começar",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(spans.count == 1)
        #expect(spans.first?.text == "vamos começar")
        #expect(spans.first?.start == 10)
        #expect(spans.first?.end == 11)
    }

    /// The failure this guard exists for: timings on a different timeline than
    /// the result would read as a correct transcript with every word at the
    /// start of the recording, and speaker attribution would collapse onto
    /// whoever spoke first. Better to lose the granularity than the timeline.
    @Test func wordsOffTheResultTimelineAreRefused() {
        let spans = OnDeviceTranscriber.spans(
            words: [
                TimedWord(text: "vamos", start: 0, end: 0.4),
                TimedWord(text: "começar", start: 0.4, end: 1.0)
            ],
            text: "vamos começar",
            resultStart: 600,
            resultEnd: 601,
            duration: 3600
        )
        #expect(spans.count == 1)
        #expect(spans.first?.start == 600)
    }

    @Test func wordsRunningPastTheResultAreRefused() {
        let spans = OnDeviceTranscriber.spans(
            words: [TimedWord(text: "vamos", start: 10, end: 45)],
            text: "vamos",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(spans.count == 1)
        #expect(spans.first?.end == 11)
    }

    // MARK: - Expansion through the quality filter

    /// Words are emitted only for segments that survive. A hallucinated segment's
    /// words are exactly as invented as the segment, so filtering them
    /// individually would be filtering nothing.
    @Test func rejectedSegmentsTakeTheirWordsWithThem() {
        let good = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "primeiro ponto", start: 0, end: 2, confidence: nil),
            quality: SpanQuality(averageLogProb: -0.2, noSpeechProb: 0.05, compressionRatio: 1.4),
            words: [
                TimedWord(text: "primeiro", start: 0, end: 1),
                TimedWord(text: "ponto", start: 1, end: 2)
            ]
        )
        let hallucinated = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "Thank you for watching.", start: 2, end: 4, confidence: nil),
            quality: SpanQuality(averageLogProb: -1.6, noSpeechProb: 0.95, compressionRatio: 1.2),
            words: [
                TimedWord(text: "Thank", start: 2, end: 3),
                TimedWord(text: "watching", start: 3, end: 4)
            ]
        )

        let kept = TranscriptQualityFilter.keeping([good, hallucinated], engine: "test")
        #expect(kept.map(\.text) == ["primeiro", "ponto"])
        // The segment's confidence rides down onto each of its words.
        #expect(kept.allSatisfy { ($0.confidence ?? 0) > 0.8 })
    }

    @Test func aSegmentWithoutWordsStaysOneSpan() {
        let item = TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: "primeiro ponto", start: 30, end: 32, confidence: nil),
            quality: .unknown
        )
        let kept = TranscriptQualityFilter.keeping([item], engine: "test")
        #expect(kept.count == 1)
        // Not [0, 32]: a segment starting at 30 must not be rewritten to start at
        // the beginning of the recording.
        #expect(kept.first?.start == 30)
        #expect(kept.first?.end == 32)
    }

    // MARK: - Cloud response

    @Test func decodesWordsAndGroupsThemUnderTheirSegment() throws {
        let json = """
        {
          "text": "primeiro ponto segundo ponto",
          "language": "portuguese",
          "segments": [
            {"start": 0.0, "end": 2.0, "text": " primeiro ponto",
             "avg_logprob": -0.2, "no_speech_prob": 0.01, "compression_ratio": 1.3},
            {"start": 2.0, "end": 4.0, "text": " segundo ponto",
             "avg_logprob": -0.3, "no_speech_prob": 0.02, "compression_ratio": 1.3}
          ],
          "words": [
            {"word": "primeiro", "start": 0.0, "end": 0.9},
            {"word": "ponto", "start": 0.9, "end": 2.0},
            {"word": "segundo", "start": 2.0, "end": 2.9},
            {"word": "ponto", "start": 2.9, "end": 4.0}
          ]
        }
        """
        let transcript = try OpenAIProvider.transcript(
            from: Data(json.utf8),
            provider: .openAI
        )
        #expect(transcript.spans.map(\.text) == ["primeiro", "ponto", "segundo", "ponto"])
        #expect(transcript.spans[2].start == 2.0)
        #expect(transcript.language == "portuguese")
    }

    /// A vendor that ignores `timestamp_granularities[]` returns no `words`. The
    /// transcript must come back segment-shaped rather than empty.
    @Test func aResponseWithoutWordsStillProducesSegments() throws {
        let json = """
        {
          "text": "primeiro ponto",
          "language": "portuguese",
          "segments": [
            {"start": 0.0, "end": 2.0, "text": " primeiro ponto",
             "avg_logprob": -0.2, "no_speech_prob": 0.01, "compression_ratio": 1.3}
          ]
        }
        """
        let transcript = try OpenAIProvider.transcript(
            from: Data(json.utf8),
            provider: .openAI
        )
        #expect(transcript.spans.map(\.text) == ["primeiro ponto"])
    }

    @Test func wordsOfADroppedSegmentDoNotSurvive() throws {
        let json = """
        {
          "text": "Thank you for watching.",
          "language": "english",
          "segments": [
            {"start": 0.0, "end": 3.0, "text": " Thank you for watching.",
             "avg_logprob": -1.4, "no_speech_prob": 0.92, "compression_ratio": 1.1}
          ],
          "words": [
            {"word": "Thank", "start": 0.0, "end": 1.0},
            {"word": "watching", "start": 1.0, "end": 3.0}
          ]
        }
        """
        let transcript = try OpenAIProvider.transcript(
            from: Data(json.utf8),
            provider: .openAI
        )
        #expect(transcript.spans.isEmpty)
    }
}
