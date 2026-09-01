//
//  TranscriptionPipelineFingerprintTests.swift
//  KurnTests
//
//  H4: mutating any single component of the fingerprint must invalidate a
//  resume, and an unverified source (no digest) must never match anything —
//  including another equally unverified fingerprint.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct TranscriptionPipelineFingerprintTests {

    private func base() -> TranscriptionPipelineFingerprint {
        TranscriptionPipelineFingerprint(
            sourceFileSize: 1_234_567,
            sourceDuration: 900.123,
            sourceDigest: "abc123",
            preprocessing: .standardDSP,
            vad: .energyThreshold,
            language: .english,
            engine: .whisperCpp,
            providerID: "whispercpp:small",
            compacted: true,
            compactionDigest: "map-digest"
        )
    }

    @Test func identicalFingerprintsAreEqual() {
        #expect(base() == base())
    }

    @Test func durationIsRoundedSoFloatJitterDoesNotBreakEquality() {
        var a = base()
        var b = base()
        a.sourceDuration = 900.1231
        b.sourceDuration = 900.1234
        #expect(a == b)
    }

    @Test func mutatingAnySingleFieldInvalidatesEquality() {
        let reference = base()

        var algorithmVersion = reference
        algorithmVersion.algorithmVersion += 1
        #expect(algorithmVersion != reference)

        var fileSize = reference
        fileSize.sourceFileSize += 1
        #expect(fileSize != reference)

        var duration = reference
        duration.sourceDuration += 10
        #expect(duration != reference)

        var digest = reference
        digest.sourceDigest = "different"
        #expect(digest != reference)

        var preprocessing = reference
        preprocessing.preprocessingRaw = PreprocessingEngine.none.rawValue
        #expect(preprocessing != reference)

        var vad = reference
        vad.vadRaw = VADEngine.fluidAudio.rawValue
        #expect(vad != reference)

        var language = reference
        language.languageRaw = MeetingLanguage.portuguese.rawValue
        #expect(language != reference)

        var engine = reference
        engine.engineRaw = TranscriptionEngine.whisperAPI.rawValue
        #expect(engine != reference)

        var providerID = reference
        providerID.providerID = "whispercpp:large-v3-turbo"
        #expect(providerID != reference)

        var compacted = reference
        compacted.compacted = false
        #expect(compacted != reference)

        var compactionDigest = reference
        compactionDigest.compactionDigest = "different-map"
        #expect(compactionDigest != reference)
    }

    @Test func noSourceDigestNeverMatchesEvenItself() {
        var unverified = base()
        unverified.sourceDigest = nil
        #expect(unverified != unverified)

        var otherUnverified = base()
        otherUnverified.sourceDigest = nil
        #expect(unverified != otherUnverified)
    }

    @Test func codableRoundTripPreservesEveryField() throws {
        let original = base()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionPipelineFingerprint.self, from: data)
        #expect(decoded == original)
        #expect(decoded.algorithmVersion == original.algorithmVersion)
        #expect(decoded.providerID == original.providerID)
        #expect(decoded.compactionDigest == original.compactionDigest)
    }
}
