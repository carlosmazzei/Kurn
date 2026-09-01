//
//  TranscriptionCheckpointTests.swift
//  KurnTests
//
//  The checkpoint is the durable state that lets an interrupted chunked
//  transcription resume instead of starting over: it must round-trip through
//  its JSON encoding on `Recording`, seed the chunk runner correctly, and be
//  rejected whenever its pipeline fingerprint (H4) doesn't match the run being
//  attempted, or its own spans don't pass structural sanity.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct TranscriptionCheckpointTests {

    private func sampleCheckpoint() -> TranscriptionCheckpoint {
        .fixture(
            engine: .whisperAPI,
            language: .english,
            compacted: true,
            totalChunks: 3,
            completedChunks: 2,
            detectedLanguage: "en",
            spans: [
                .init(text: "hello", start: 0, end: 1.5, confidence: 0.9),
                .init(text: "world", start: 601, end: 603, confidence: nil)
            ],
            sourceDuration: 700
        )
    }

    private func fingerprint(of checkpoint: TranscriptionCheckpoint) -> TranscriptionPipelineFingerprint {
        checkpoint.fingerprint
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let original = sampleCheckpoint()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)

        #expect(decoded.engineRaw == original.engineRaw)
        #expect(decoded.languageRaw == original.languageRaw)
        #expect(decoded.compacted == original.compacted)
        #expect(decoded.chunkPlanDigest == original.chunkPlanDigest)
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

    @Test func recordingWritesCheckpointAsVersionedEnvelope() throws {
        // The stored bytes must decode through the authoritative envelope
        // path, not only as bare legacy JSON.
        let recording = Recording(fileName: "a.m4a", duration: 10)
        recording.transcriptionCheckpoint = sampleCheckpoint()

        let data = try #require(recording.transcriptionCheckpointData)
        // Envelope-wrapped bytes are not bare checkpoint JSON…
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
        }
        // …but read back correctly through the authoritative path.
        #expect(recording.transcriptionCheckpointOutcome.decodedValue?.completedChunks == 2)
    }

    @Test func legacyBareCheckpointStillDecodes() throws {
        // Rows written before the envelope existed store bare
        // `TranscriptionCheckpoint` JSON; they are real content, not corruption.
        let recording = Recording(fileName: "a.m4a", duration: 10)
        recording.transcriptionCheckpointData = try JSONEncoder().encode(sampleCheckpoint())

        #expect(recording.transcriptionCheckpoint?.completedChunks == 2)
        #expect(!recording.transcriptionCheckpointOutcome.isCorrupted)
    }

    @Test func corruptedCheckpointIsDistinctFromAbsentAndPreservesBytes() {
        let recording = Recording(fileName: "a.m4a", duration: 10)
        let garbage = Data([0x7B, 0x22, 0xFF, 0x00])
        recording.transcriptionCheckpointData = garbage

        #expect(recording.transcriptionCheckpoint == nil)
        #expect(recording.transcriptionCheckpointOutcome.isCorrupted)
        #expect(recording.transcriptionCheckpointData == garbage)

        recording.transcriptionCheckpointData = nil
        if case .empty = recording.transcriptionCheckpointOutcome {} else {
            Issue.record("absent checkpoint must be .empty, not .corrupted")
        }
    }

    @Test func tamperedEnvelopeChecksumIsCorruption() throws {
        // A bit-level change that still parses as valid JSON must be caught
        // by the checksum, not silently accepted.
        let recording = Recording(fileName: "a.m4a", duration: 10)
        recording.transcriptionCheckpoint = sampleCheckpoint()
        var data = try #require(recording.transcriptionCheckpointData)
        let text = try #require(String(data: data, encoding: .utf8))
        let tampered = text.replacingOccurrences(of: "\"payloadChecksum\":", with: "\"payloadChecksum\":1")
        data = Data(tampered.utf8)
        recording.transcriptionCheckpointData = data

        #expect(recording.transcriptionCheckpointOutcome.isCorrupted)
        #expect(recording.transcriptionCheckpoint == nil)
    }

    @Test func encodeFailureKeepsThePreviousCheckpoint() {
        // JSON has no representation for a non-finite Double; the setter must
        // keep the older resumable point rather than blank or corrupt it.
        let recording = Recording(fileName: "a.m4a", duration: 10)
        recording.transcriptionCheckpoint = sampleCheckpoint()
        let stored = recording.transcriptionCheckpointData

        var bad = sampleCheckpoint()
        bad.spans = [.init(text: "x", start: .nan, end: .infinity, confidence: nil)]
        recording.transcriptionCheckpoint = bad

        #expect(recording.transcriptionCheckpointData == stored)
        #expect(recording.transcriptionCheckpoint?.completedChunks == 2)
    }

    // MARK: - Fingerprint matching (H4)

    @Test func matchesRequiresSameEngineLanguageAndCompaction() {
        let checkpoint = sampleCheckpoint()
        let base = fingerprint(of: checkpoint)
        #expect(checkpoint.matches(base))

        var wrongEngine = base
        wrongEngine.engineRaw = TranscriptionEngine.appleSpeech.rawValue
        #expect(!checkpoint.matches(wrongEngine))

        var wrongLanguage = base
        wrongLanguage.languageRaw = MeetingLanguage.portuguese.rawValue
        #expect(!checkpoint.matches(wrongLanguage))

        var wrongCompaction = base
        wrongCompaction.compacted = false
        #expect(!checkpoint.matches(wrongCompaction))
    }

    @Test func matchesRequiresSameTranscriptionProvider() {
        // A checkpoint recorded against one Whisper provider must not seed a
        // resume for a different provider (which would stitch two vendors'
        // chunks together). A legacy checkpoint (providerID nil) also won't
        // match a provider-scoped resume.
        let openAICheckpoint = TranscriptionCheckpoint.fixture(
            engine: .whisperAPI, language: .english, compacted: true,
            totalChunks: 3, completedChunks: 2, detectedLanguage: "en",
            spans: [], providerID: AIProvider.openAI.id
        )
        let base = fingerprint(of: openAICheckpoint)
        #expect(openAICheckpoint.matches(base))

        var groqFingerprint = base
        groqFingerprint.providerID = AIProvider.groq.id
        #expect(!openAICheckpoint.matches(groqFingerprint))

        var noProviderFingerprint = base
        noProviderFingerprint.providerID = nil
        #expect(!openAICheckpoint.matches(noProviderFingerprint))
    }

    @Test func matchesRequiresSameSourceDigest() {
        // Same everything else, different source bytes: a re-recorded or
        // replaced file must never resume from another file's spans.
        let checkpoint = sampleCheckpoint()
        var mutatedSource = fingerprint(of: checkpoint)
        mutatedSource.sourceDigest = "different-source"
        #expect(!checkpoint.matches(mutatedSource))
    }

    @Test func matchesRequiresSamePreprocessingVADAndCompactionDigest() {
        let checkpoint = sampleCheckpoint()
        let base = fingerprint(of: checkpoint)

        var differentPreprocessing = base
        differentPreprocessing.preprocessingRaw = PreprocessingEngine.none.rawValue
        #expect(!checkpoint.matches(differentPreprocessing))

        var differentVAD = base
        differentVAD.vadRaw = VADEngine.fluidAudio.rawValue
        #expect(!checkpoint.matches(differentVAD))

        var differentCompactionMap = base
        differentCompactionMap.compactionDigest = "a-different-map"
        #expect(!checkpoint.matches(differentCompactionMap))
    }

    @Test func unverifiedSourceNeverMatchesAnything() {
        // A fingerprint with no digest (an unreadable/unvalidated source)
        // must never match, including another equally unverified one.
        let checkpoint = TranscriptionCheckpoint.fixture(
            engine: .whisperAPI, language: .english, compacted: false,
            totalChunks: 1, completedChunks: 0, detectedLanguage: "",
            spans: [], sourceDigest: nil
        )
        var attempted = checkpoint.fingerprint
        attempted.sourceDigest = nil
        #expect(!checkpoint.matches(attempted))
    }

    // MARK: - Structural validity (H4)

    @Test func structurallyValidCheckpointPassesValidation() {
        #expect(sampleCheckpoint().isStructurallyValid)
    }

    @Test func negativeOrOutOfBoundsCompletedChunksIsInvalid() {
        var checkpoint = sampleCheckpoint()
        checkpoint.completedChunks = -1
        #expect(!checkpoint.isStructurallyValid)

        checkpoint = sampleCheckpoint()
        checkpoint.completedChunks = checkpoint.totalChunks + 1
        #expect(!checkpoint.isStructurallyValid)
    }

    @Test func nonFiniteOrNegativeSpanTimestampsAreInvalid() {
        var checkpoint = sampleCheckpoint()
        checkpoint.spans = [.init(text: "x", start: .nan, end: 1, confidence: nil)]
        #expect(!checkpoint.isStructurallyValid)

        checkpoint = sampleCheckpoint()
        checkpoint.spans = [.init(text: "x", start: -5, end: 1, confidence: nil)]
        #expect(!checkpoint.isStructurallyValid)

        checkpoint = sampleCheckpoint()
        checkpoint.spans = [.init(text: "x", start: 5, end: 1, confidence: nil)]
        #expect(!checkpoint.isStructurallyValid)
    }

    @Test func spanBeyondSourceDurationIsInvalid() {
        var checkpoint = sampleCheckpoint()
        // sampleCheckpoint's source duration is 700s; far beyond any slack.
        checkpoint.spans = [.init(text: "x", start: 10_000, end: 10_001, confidence: nil)]
        #expect(!checkpoint.isStructurallyValid)
    }

    @Test func runnerProgressBridgesBothWays() {
        let checkpoint = sampleCheckpoint()
        let progress = checkpoint.runnerProgress
        #expect(progress.totalChunks == 3)
        #expect(progress.completedChunks == 2)
        #expect(progress.planDigest == checkpoint.chunkPlanDigest)
        #expect(progress.spans.count == 2)
        #expect(progress.spans[0].text == "hello")

        let rebuilt = TranscriptionCheckpoint(fingerprint: checkpoint.fingerprint, progress: progress)
        #expect(rebuilt.totalChunks == checkpoint.totalChunks)
        #expect(rebuilt.completedChunks == checkpoint.completedChunks)
        #expect(rebuilt.chunkPlanDigest == checkpoint.chunkPlanDigest)
        #expect(rebuilt.spans.count == checkpoint.spans.count)
    }
}
