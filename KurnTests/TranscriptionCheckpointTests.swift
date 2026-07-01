//
//  TranscriptionCheckpointTests.swift
//  KurnTests
//
//  The checkpoint is the durable state that lets an interrupted chunked
//  transcription resume instead of starting over: it must round-trip through
//  its JSON encoding on `Recording`, seed the chunk runner correctly, and be
//  rejected whenever the re-derived plan doesn't match the one it was saved
//  against.
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptionCheckpointTests {

    private func sampleCheckpoint() -> TranscriptionCheckpoint {
        TranscriptionCheckpoint(
            engineRaw: TranscriptionEngine.whisperAPI.rawValue,
            languageRaw: MeetingLanguage.english.rawValue,
            compacted: true,
            totalChunks: 3,
            completedChunks: 2,
            detectedLanguage: "en",
            spans: [
                .init(text: "hello", start: 0, end: 1.5, confidence: 0.9),
                .init(text: "world", start: 601, end: 603, confidence: nil)
            ]
        )
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let original = sampleCheckpoint()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)

        #expect(decoded.engineRaw == original.engineRaw)
        #expect(decoded.languageRaw == original.languageRaw)
        #expect(decoded.compacted == original.compacted)
        #expect(decoded.totalChunks == 3)
        #expect(decoded.completedChunks == 2)
        #expect(decoded.detectedLanguage == "en")
        #expect(decoded.spans.count == 2)
        #expect(decoded.spans[0].text == "hello")
        #expect(decoded.spans[1].start == 601)
        #expect(decoded.spans[1].confidence == nil)
    }

    @Test func recordingStoresCheckpointAsData() {
        let recording = Recording(fileName: "a.m4a", duration: 10)
        #expect(recording.transcriptionCheckpoint == nil)

        recording.transcriptionCheckpoint = sampleCheckpoint()
        #expect(recording.transcriptionCheckpointData != nil)
        #expect(recording.transcriptionCheckpoint?.completedChunks == 2)

        recording.transcriptionCheckpoint = nil
        #expect(recording.transcriptionCheckpointData == nil)
    }

    @Test func matchesRequiresSameEngineLanguageAndCompaction() {
        let checkpoint = sampleCheckpoint()
        #expect(checkpoint.matches(engine: .whisperAPI, language: .english, compacted: true))
        #expect(!checkpoint.matches(engine: .appleSpeech, language: .english, compacted: true))
        #expect(!checkpoint.matches(engine: .whisperAPI, language: .portuguese, compacted: true))
        #expect(!checkpoint.matches(engine: .whisperAPI, language: .english, compacted: false))
    }

    @Test func runnerProgressBridgesBothWays() {
        let checkpoint = sampleCheckpoint()
        let progress = checkpoint.runnerProgress
        #expect(progress.totalChunks == 3)
        #expect(progress.completedChunks == 2)
        #expect(progress.spans.count == 2)
        #expect(progress.spans[0].text == "hello")

        let rebuilt = TranscriptionCheckpoint(
            engine: .whisperAPI, language: .english, compacted: true, progress: progress
        )
        #expect(rebuilt.totalChunks == checkpoint.totalChunks)
        #expect(rebuilt.completedChunks == checkpoint.completedChunks)
        #expect(rebuilt.spans.count == checkpoint.spans.count)
    }
}
