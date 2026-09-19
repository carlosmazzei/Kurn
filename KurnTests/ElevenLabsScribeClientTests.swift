//
//  ElevenLabsScribeClientTests.swift
//  KurnTests
//
//  Response decoding for ElevenLabs Scribe, mirroring WordTimestampTests'
//  coverage of OpenAIProvider.transcript(from:) — no network involved, just
//  captured response shapes.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ElevenLabsScribeClientTests {

    @Test func wordTypedEntriesBecomeTimedSpans() throws {
        let json = """
        {
          "text": "primeiro ponto",
          "language_code": "por",
          "audio_duration_secs": 2.0,
          "words": [
            {"text": "primeiro", "start": 0.0, "end": 0.8, "type": "word"},
            {"text": " ", "start": 0.8, "end": 0.9, "type": "spacing"},
            {"text": "ponto", "start": 0.9, "end": 1.5, "type": "word"}
          ]
        }
        """
        let transcript = try ElevenLabsScribeClient.transcript(from: Data(json.utf8))
        #expect(transcript.spans.map(\.text) == ["primeiro", "ponto"])
        #expect(transcript.spans[0].start == 0.0)
        #expect(transcript.spans[1].end == 1.5)
        #expect(transcript.language == "por")
    }

    @Test func spacingAndAudioEventEntriesAreIgnoredForSpanBuilding() throws {
        let json = """
        {
          "text": "hello",
          "words": [
            {"text": "(laughter)", "start": 0.0, "end": 1.0, "type": "audio_event"},
            {"text": " ", "start": 1.0, "end": 1.1, "type": "spacing"}
          ]
        }
        """
        // No "word"-type entries survive the filter, so this falls back to the
        // whole-blob span rather than fabricating spans from noise.
        let transcript = try ElevenLabsScribeClient.transcript(from: Data(json.utf8))
        #expect(transcript.spans.map(\.text) == ["hello"])
    }

    /// No `words` array at all (e.g. word timestamps weren't requested) still
    /// produces a usable transcript — one whole-file span.
    @Test func aResponseWithoutWordsStillProducesOneSpan() throws {
        let json = """
        {
          "text": "primeiro ponto, segundo ponto",
          "language_code": "por"
        }
        """
        let transcript = try ElevenLabsScribeClient.transcript(from: Data(json.utf8))
        #expect(transcript.spans.map(\.text) == ["primeiro ponto, segundo ponto"])
    }

    @Test func missingLanguageCodeDecodesToEmptyString() throws {
        let json = """
        { "text": "hello" }
        """
        let transcript = try ElevenLabsScribeClient.transcript(from: Data(json.utf8))
        #expect(transcript.language == "")
    }

    @Test func malformedResponseThrowsDecodingError() {
        let json = "{ not valid json"
        #expect(throws: AppError.self) {
            try ElevenLabsScribeClient.transcript(from: Data(json.utf8))
        }
    }
}
