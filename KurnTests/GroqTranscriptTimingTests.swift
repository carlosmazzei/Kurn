import Foundation
import KurnCore
import Testing
@testable import Kurn

struct GroqTranscriptTimingTests {
    @Test func wordOnASharedSegmentBoundaryIsEmittedOnlyOnce() throws {
        let json = """
        {
          "text": "first shared last",
          "segments": [
            {"start": 0.0, "end": 2.0, "text": "first shared"},
            {"start": 2.0, "end": 4.0, "text": "last"}
          ],
          "words": [
            {"word": "first", "start": 0.0, "end": 1.0},
            {"word": "shared", "start": 1.8, "end": 2.2},
            {"word": "last", "start": 3.0, "end": 4.0}
          ]
        }
        """
        let raw = try OpenAIProvider.transcript(from: Data(json.utf8), provider: .groq)
        #expect(raw.spans.map(\.text) == ["first", "shared", "last"])
    }

    @Test func realZeroDurationAPIWordIsNotLost() throws {
        let json = """
        {
          "text": "first instant last",
          "segments": [{"start": 0.0, "end": 3.0, "text": "first instant last"}],
          "words": [
            {"word": "first", "start": 0.0, "end": 1.0},
            {"word": "instant", "start": 1.0, "end": 1.0},
            {"word": "last", "start": 1.0, "end": 2.0}
          ]
        }
        """
        let raw = try OpenAIProvider.transcript(from: Data(json.utf8), provider: .groq)
        #expect(raw.spans.map(\.text) == ["first", "instant", "last"])
        #expect(raw.spans.map(\.start) == [0, 1, 1])
        #expect(raw.spans.map(\.end) == [1, 1, 2])
    }

    @Test func reorderedAPIWordsFuseWithoutInvertingTheSegment() throws {
        let json = """
        {
          "text": "primeira segunda",
          "language": "Portuguese",
          "segments": [
            {"start": 300.0, "end": 303.0, "text": "primeira segunda", "avg_logprob": -0.2}
          ],
          "words": [
            {"word": "primeira", "start": 301.5, "end": 302.0},
            {"word": "segunda", "start": 300.1, "end": 300.4}
          ]
        }
        """
        let raw = try OpenAIProvider.transcript(from: Data(json.utf8), provider: .groq)
        #expect(raw.language == "Portuguese")
        #expect(raw.spans.map(\.text) == ["primeira", "segunda"])
        let result = TranscriptFusion.segments(
            spans: raw.spans,
            turns: [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 5707.3)]
        )
        #expect(result.count == 1)
        #expect(result.first?.text == "primeira segunda")
        #expect(result.first?.startTime == 300.1)
        #expect(result.first?.endTime == 302)
        #expect(TranscriptIntegrityGate.validate(segments: result, sourceDuration: 5707.3, hadTranscribedInput: true) == nil)
    }

    @Test func groqResponseWithoutWordTimingsKeepsTextAndSpeakerAttribution() throws {
        let json = """
        {
          "text": "Uma frase completa.",
          "language": "Portuguese",
          "segments": [
            {"start": 10.0, "end": 12.0, "text": " Uma frase completa.", "avg_logprob": -0.2}
          ]
        }
        """
        let raw = try OpenAIProvider.transcript(from: Data(json.utf8), provider: .groq)
        let result = TranscriptFusion.segments(
            spans: raw.spans,
            turns: [SpeakerTurn(speakerLabel: "Speaker 2", start: 0, end: 20)]
        )
        #expect(result.count == 1)
        #expect(result.first?.text == "Uma frase completa.")
        #expect(result.first?.speakerLabel == "Speaker 2")
        #expect(result.first?.startTime == 10)
        #expect(result.first?.endTime == 12)
    }
}
