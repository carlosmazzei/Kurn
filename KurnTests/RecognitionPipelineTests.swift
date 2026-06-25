//
//  RecognitionPipelineTests.swift
//  KurnTests
//
//  Covers the modular recognition pipeline: the legacy→`TranscriptionEngine`
//  settings migration, the per-stage engine metadata (storage mode / required
//  model set), language-code mapping, the shared energy-VAD segmentation, and
//  the default `PipelineConfiguration`.
//

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
}
