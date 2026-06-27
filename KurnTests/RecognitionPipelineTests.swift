//
//  RecognitionPipelineTests.swift
//  KurnTests
//
//  Covers the modular recognition pipeline: the legacy→`TranscriptionEngine`
//  settings migration, the per-stage engine metadata (storage mode / required
//  model set), language-code mapping, the shared energy-VAD segmentation, and
//  the default `PipelineConfiguration`.
//

import Foundation
import Testing
@testable import Kurn

struct RecognitionPipelineTests {

    // MARK: - Legacy settings migration

    @Test func whisperModeMigratesToWhisperEngine() {
        let engine = AppSettings.migratedTranscriptionEngine(
            mode: .whisperAPI, language: .autoDetect, multilingualConsented: true
        )
        #expect(engine == .whisperAPI)
    }

    @Test func onDeviceAutoWithMultilingualConsentMigratesToParakeet() {
        let engine = AppSettings.migratedTranscriptionEngine(
            mode: .onDevice, language: .autoDetect, multilingualConsented: true
        )
        #expect(engine == .fluidAudioParakeet)
    }

    @Test func onDeviceAutoWithoutConsentMigratesToAppleSpeech() {
        let engine = AppSettings.migratedTranscriptionEngine(
            mode: .onDevice, language: .autoDetect, multilingualConsented: false
        )
        #expect(engine == .appleSpeech)
    }

    @Test func onDevicePinnedLanguageMigratesToAppleSpeech() {
        let engine = AppSettings.migratedTranscriptionEngine(
            mode: .onDevice, language: .portuguese, multilingualConsented: true
        )
        #expect(engine == .appleSpeech)
    }

    // MARK: - Engine metadata

    @Test func storageModeMapsOnDeviceEnginesToOnDevice() {
        #expect(TranscriptionEngine.appleSpeech.storageMode == .onDevice)
        #expect(TranscriptionEngine.fluidAudioParakeet.storageMode == .onDevice)
        #expect(TranscriptionEngine.whisperAPI.storageMode == .whisperAPI)
    }

    @Test func requiredModelSetOnlyForFluidAudioEngines() {
        #expect(TranscriptionEngine.appleSpeech.requiredModelSet == nil)
        #expect(TranscriptionEngine.whisperAPI.requiredModelSet == nil)
        #expect(TranscriptionEngine.fluidAudioParakeet.requiredModelSet == .onDeviceASR)
        #expect(LanguageDetectionEngine.byTranscriber.requiredModelSet == nil)
        #expect(LanguageDetectionEngine.fluidAudioLID.requiredModelSet == .onDeviceASR)
        #expect(DiarizationEngine.heuristic.requiredModelSet == nil)
        #expect(DiarizationEngine.fluidAudio.requiredModelSet == .diarization)
        #expect(VADEngine.energyThreshold.requiredModelSet == nil)
        #expect(VADEngine.fluidAudio.requiredModelSet == .vad)
    }

    // MARK: - Language code mapping

    @Test(arguments: [
        ("pt", MeetingLanguage.portuguese),
        ("pt-BR", MeetingLanguage.portuguese),
        ("en", MeetingLanguage.english),
        ("es", MeetingLanguage.spanish),
        ("fr", MeetingLanguage.french),
        ("de", MeetingLanguage.german),
        ("ja", MeetingLanguage.japanese),
        ("zh-Hans", MeetingLanguage.chinese),
        ("ru", MeetingLanguage.autoDetect)
    ])
    func detectedCodeMapsToLanguage(code: String, expected: MeetingLanguage) {
        #expect(MeetingLanguage(detectedCode: code) == expected)
    }

    // MARK: - Energy VAD segmentation

    @Test func vadFindsSpeechRegionSeparatedBySilence() {
        // Two loud frames then a >=0.5s silence gap (5 frames) then the rest silent.
        let dbfs: [Float] = [-50, -50, -10, -10, -10, -50, -50, -50, -50, -50, -50]
        let ranges = EnergyVAD.speechFrameRanges(dbfs: dbfs)
        #expect(ranges.count == 1)
        #expect(ranges.first?.start == 2)
        #expect(ranges.first?.end == 4)
    }

    @Test func vadKeepsTrailingSpeechWithoutTrailingSilence() {
        let dbfs: [Float] = [-50, -10, -10]
        let ranges = EnergyVAD.speechFrameRanges(dbfs: dbfs)
        #expect(ranges.count == 1)
        #expect(ranges.first?.start == 1)
        #expect(ranges.first?.end == 2)
    }

    @Test func vadDropsSubMinimumBlips() {
        // A single loud frame is shorter than `minRegionFrames` (2) and dropped.
        let dbfs: [Float] = [-50, -10, -50, -50, -50, -50, -50]
        let ranges = EnergyVAD.speechFrameRanges(dbfs: dbfs)
        #expect(ranges.isEmpty)
    }

    // MARK: - Default configuration

    @Test func defaultConfigurationUsesAlwaysAvailableEngines() {
        let config = PipelineConfiguration()
        #expect(config.preprocessing == .standardDSP)
        #expect(config.vad == .energyThreshold)
        #expect(config.languageDetection == .byTranscriber)
        #expect(config.diarization == .heuristic)
        #expect(config.transcription == .appleSpeech)
    }

    // MARK: - VAD audio compaction (timeline remap + region normalization)

    private func isClose(_ lhs: TimeInterval?, _ rhs: TimeInterval, tolerance: TimeInterval = 1e-6) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }

    /// Two regions with a 0.5 s seam gap: 0–3 s ← original 5 s; 3.5–5.5 s ← original 20 s.
    private var sampleMap: [TimelineSegment] {
        [
            TimelineSegment(compactedStart: 0, originalStart: 5, duration: 3),
            TimelineSegment(compactedStart: 3.5, originalStart: 20, duration: 2)
        ]
    }

    @Test func remapWithinRegionsIsLinear() {
        #expect(isClose(VADAudioCompactor.remap(0, map: sampleMap), 5))      // start of first region
        #expect(isClose(VADAudioCompactor.remap(1.5, map: sampleMap), 6.5))  // mid first region
        #expect(isClose(VADAudioCompactor.remap(3.0, map: sampleMap), 8))    // end of first region
        #expect(isClose(VADAudioCompactor.remap(4.0, map: sampleMap), 20.5)) // inside second region
    }

    @Test func remapSnapsSeamGapAndTailToBoundaries() {
        // A time in the inter-region gap snaps to the previous region's end (8).
        #expect(isClose(VADAudioCompactor.remap(3.2, map: sampleMap), 8))
        // Past the last region snaps to its end (20 + 2).
        #expect(isClose(VADAudioCompactor.remap(10, map: sampleMap), 22))
    }

    @Test func remapWithEmptyMapIsIdentity() {
        #expect(isClose(VADAudioCompactor.remap(4.2, map: []), 4.2))
    }

    @Test func normalizeMergesOverlappingPaddedRegions() {
        let regions = [SpeechRegion(start: 1, end: 2), SpeechRegion(start: 2.1, end: 3)]
        let merged = VADAudioCompactor.normalize(regions: regions, pad: 0.25, totalDuration: 10)
        #expect(merged.count == 1)
        #expect(isClose(merged.first?.start, 0.75))
        #expect(isClose(merged.first?.end, 3.25))
    }

    @Test func normalizeClampsPaddingToClipBounds() {
        let merged = VADAudioCompactor.normalize(
            regions: [SpeechRegion(start: 0, end: 1)], pad: 0.25, totalDuration: 10
        )
        #expect(merged.count == 1)
        #expect(isClose(merged.first?.start, 0))   // clamped at 0, not -0.25
        #expect(isClose(merged.first?.end, 1.25))
    }
}
