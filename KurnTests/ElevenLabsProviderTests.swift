//
//  ElevenLabsProviderTests.swift
//  KurnTests
//
//  Response decoding for ElevenLabs Scribe, mirroring WordTimestampTests'
//  coverage of OpenAIProvider.transcript(from:) — no network involved, just
//  captured response shapes. Also covers grouping `speaker_id` into
//  `SpeakerTurn`s (native diarization) and the two unsupported-capability
//  throws that make ElevenLabs a transcription-only `LLMProvider`.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

// Serialized because `transcribeRequestAlwaysIncludesDiarizeField` uses
// `MockURLProtocol`, whose scripted state is process-global (see its header).
@Suite(.serialized)
struct ElevenLabsProviderTests {

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
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
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
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
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
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        #expect(transcript.spans.map(\.text) == ["primeiro ponto, segundo ponto"])
    }

    @Test func missingLanguageCodeDecodesToEmptyString() throws {
        let json = """
        { "text": "hello" }
        """
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        #expect(transcript.language == "")
    }

    @Test func malformedResponseThrowsDecodingError() {
        let json = "{ not valid json"
        #expect(throws: AppError.self) {
            try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        }
    }

    // MARK: - Native diarization

    @Test func speakerIdEntriesGroupIntoContiguousSpeakerTurns() throws {
        let json = """
        {
          "text": "hello there general kenobi",
          "words": [
            {"text": "hello", "start": 0.0, "end": 0.4, "type": "word", "speaker_id": "speaker_0"},
            {"text": "there", "start": 0.4, "end": 0.8, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.8, "end": 0.9, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "general", "start": 0.9, "end": 1.3, "type": "word", "speaker_id": "speaker_1"},
            {"text": "kenobi", "start": 1.3, "end": 1.8, "type": "word", "speaker_id": "speaker_1"}
          ]
        }
        """
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        let turns = try #require(transcript.speakerTurns)
        #expect(turns.count == 2)
        #expect(turns[0].speakerLabel == "Speaker 1")
        #expect(turns[0].start == 0.0)
        #expect(turns[0].end == 0.8)
        #expect(turns[1].speakerLabel == "Speaker 2")
        #expect(turns[1].start == 0.9)
        #expect(turns[1].end == 1.8)
    }

    @Test func nonAdjacentSameSpeakerRunsProduceSeparateTurns() throws {
        // The same speaker returning after someone else in between must not
        // merge into the earlier turn.
        let json = """
        {
          "text": "a b a",
          "words": [
            {"text": "a", "start": 0.0, "end": 0.2, "type": "word", "speaker_id": "speaker_0"},
            {"text": "b", "start": 0.2, "end": 0.4, "type": "word", "speaker_id": "speaker_1"},
            {"text": "a", "start": 0.4, "end": 0.6, "type": "word", "speaker_id": "speaker_0"}
          ]
        }
        """
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        let turns = try #require(transcript.speakerTurns)
        #expect(turns.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func noSpeakerIdAnywhereLeavesSpeakerTurnsNil() throws {
        let json = """
        {
          "text": "hello",
          "words": [
            {"text": "hello", "start": 0.0, "end": 0.4, "type": "word"}
          ]
        }
        """
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        #expect(transcript.speakerTurns == nil)
    }

    @Test func responseWithoutWordsLeavesSpeakerTurnsNil() throws {
        let json = """
        { "text": "hello" }
        """
        let transcript = try ElevenLabsProvider.transcript(from: Data(json.utf8), provider: .elevenLabs)
        #expect(transcript.speakerTurns == nil)
    }

    @Test func transcribeRequestAlwaysIncludesDiarizeField() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: Data("{ \"text\": \"hi\" }".utf8), headers: [:])
        ])
        let provider = ElevenLabsProvider(apiKey: "test-key", session: MockURLProtocol.session())
        _ = try await provider.transcribe(audioData: Data("audio".utf8), fileName: "clip.m4a", language: .autoDetect)

        let body = try #require(MockURLProtocol.lastRequest.map(MockURLProtocol.body(of:)))
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(bodyText.contains("name=\"diarize\""))
        #expect(bodyText.contains("true"))
    }

    // MARK: - Unsupported capabilities

    @Test func summarizeThrowsSummarizationUnsupported() async throws {
        let provider = ElevenLabsProvider(apiKey: "test-key")
        await #expect(throws: AppError.self) {
            try await provider.summarize(systemPrompt: "system", userPrompt: "user")
        }
    }

    @Test func chatThrowsSummarizationUnsupported() async throws {
        let provider = ElevenLabsProvider(apiKey: "test-key")
        await #expect(throws: AppError.self) {
            try await provider.chat(
                systemPrompt: "system",
                messages: [ChatMessage(role: .user, content: "hi")],
                options: .chat
            )
        }
    }
}
