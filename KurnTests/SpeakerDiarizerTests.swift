//
//  SpeakerDiarizerTests.swift
//  KurnTests
//
//  Exercises the heuristic on-device diarizer through its public actor API with
//  synthetic, lossless audio fixtures.
//
//  What this file asserts changed when the heuristic engine stopped being the
//  default and became the fallback used until the neural models are downloaded.
//  It used to claim the engine separates two distinct pitches into two speakers,
//  and that claim was `.disabled` because it does not hold — three scalars and a
//  single greedy clustering pass do not reliably separate voices, on the CI
//  simulator or anywhere else. A disabled test asserting something false is
//  worse than no test: it reads as a temporary problem rather than as the
//  engine's actual ceiling.
//
//  So these assert only what a fallback has to guarantee — never throw, never
//  return nothing, honour the regions it is given, respect the speaker cap — and
//  the accuracy claims belong to `.fluidAudio`, which is now the default.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SpeakerDiarizerTests {

    @Test func unreadableFileFallsBackToSingleSpeaker() async {
        let url = URL(fileURLWithPath: "/does/not/exist/\(UUID().uuidString).wav")
        let turns = await SpeakerDiarizer().diarize(url: url)
        #expect(turns.count == 1)
        #expect(turns.first?.speakerLabel == "Speaker 1")
    }

    /// A clip with no speech in it must still come back as something the fusion
    /// step can attribute against. The end time is deliberately not asserted:
    /// with nothing to segment there is no meaningful duration, only the
    /// requirement that a label exists.
    @Test func silentFileProducesSingleWholeClipTurn() async throws {
        let url = try AudioFixtures.wav(segments: [(0, 2.0)])
        defer { try? FileManager.default.removeItem(at: url) }

        let turns = await SpeakerDiarizer().diarize(url: url)
        #expect(turns.count == 1)
        #expect(turns.first?.speakerLabel == "Speaker 1")
    }

    /// Not "two pitches become two speakers" — the engine does not deliver that,
    /// which is why the claim was disabled rather than fixed. What it must
    /// deliver is a usable, labelled result over audio that changes voice.
    @Test func twoSpeakerAudioStillProducesLabelledTurns() async throws {
        let url = try AudioFixtures.twoSpeakerWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let turns = await SpeakerDiarizer().diarize(url: url)
        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy { !$0.speakerLabel.isEmpty })
        #expect(turns.allSatisfy { $0.end >= $0.start })
    }

    @Test func sameVoiceRepeatedStaysOneSpeaker() async throws {
        let url = try AudioFixtures.sameSpeakerWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let turns = await SpeakerDiarizer().diarize(url: url)
        // Identical timbre on both sides of the gap clusters to one centroid, and
        // the two same-speaker turns merge back into a contiguous run.
        #expect(Set(turns.map(\.speakerLabel)).count == 1)
    }

    @Test func externalSpeechRegionsAreHonored() async throws {
        // One continuous tone; supply two external regions. The diarizer should
        // produce turns confined to those regions' span (same pitch ⇒ one label).
        let url = try AudioFixtures.wav(segments: [(150, 3.0)])
        defer { try? FileManager.default.removeItem(at: url) }

        let regions = [SpeechRegion(start: 0, end: 1.0), SpeechRegion(start: 2.0, end: 3.0)]
        let turns = await SpeakerDiarizer().diarize(url: url, speechRegions: regions)

        #expect(!turns.isEmpty)
        #expect((turns.first?.start ?? -1) >= 0)
        #expect((turns.last?.end ?? .greatestFiniteMagnitude) <= 3.0 + 0.2)
    }

    @Test func manyToneRegionsClusterWithoutExceedingCap() async throws {
        // A dozen tone regions across the human pitch range. Nearby pitches fall
        // within the clustering threshold and merge, so this never explodes into
        // a speaker-per-region.
        let pitches: [Double] = [90, 120, 150, 180, 210, 240, 270, 300, 330, 360, 390, 110]
        var segments: [(hz: Double, seconds: Double)] = []
        for pitch in pitches {
            segments.append((pitch, 0.7))
            segments.append((0, 0.7)) // >= 0.5s silence to split regions
        }
        let url = try AudioFixtures.wav(segments: segments)
        defer { try? FileManager.default.removeItem(at: url) }

        let turns = await SpeakerDiarizer().diarize(url: url)
        let speakers = Set(turns.map(\.speakerLabel))
        // Only the cap. How many clusters a dozen tones collapse into is exactly
        // what this engine is unreliable about; that it never explodes past its
        // own ceiling is the invariant worth holding it to.
        #expect(speakers.count >= 1)
        #expect(speakers.count <= 8) // SpeakerDiarizer.maxSpeakers
    }
}
