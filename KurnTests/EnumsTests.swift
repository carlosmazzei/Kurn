//
//  EnumsTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct EnumsTests {

    // MARK: - MeetingLanguage

    @Test func autoDetectHasNoLocaleOrWhisperCode() {
        #expect(MeetingLanguage.autoDetect.localeIdentifier == nil)
        #expect(MeetingLanguage.autoDetect.whisperCode == nil)
    }

    /// Regression guard: these 7 cases' rawValues, locales, and whisper codes
    /// are persisted in shipped user data (`Meeting.languageRaw`) and must
    /// never change.
    @Test(arguments: [
        (MeetingLanguage.portuguese, "pt-BR", "pt"),
        (MeetingLanguage.english, "en-US", "en"),
        (MeetingLanguage.spanish, "es-ES", "es"),
        (MeetingLanguage.french, "fr-FR", "fr"),
        (MeetingLanguage.german, "de-DE", "de"),
        (MeetingLanguage.japanese, "ja-JP", "ja"),
        (MeetingLanguage.chinese, "zh-CN", "zh")
    ])
    func legacyLocaleAndWhisperCodeUnchanged(language: MeetingLanguage, locale: String, whisperCode: String) {
        #expect(language.localeIdentifier == locale)
        #expect(language.whisperCode == whisperCode)
    }

    @Test func rawValueRoundTripsForAllCases() {
        for language in MeetingLanguage.allCases {
            #expect(MeetingLanguage(rawValue: language.rawValue) == language)
        }
    }

    @Test func everyNonAutoDetectCaseHasAWhisperCodeAndLocale() {
        for language in MeetingLanguage.allCases where language != .autoDetect {
            let code = language.whisperCode
            #expect(code != nil)
            #expect((2...3).contains(code?.count ?? 0))
            #expect(language.localeIdentifier != nil)
        }
    }

    @Test func whisperCodesAreUnique() {
        let codes = MeetingLanguage.allCases.compactMap(\.whisperCode)
        #expect(codes.count == Set(codes).count)
    }

    @Test func allCasesCountMatchesWhisperLanguageCount() {
        // 1 autoDetect + 100 languages Whisper supports.
        #expect(MeetingLanguage.allCases.count == 101)
    }

    @Test func displayNameIsNeverEmpty() {
        for language in MeetingLanguage.allCases {
            #expect(!language.displayName.isEmpty)
        }
    }

    // MARK: - AIProvider

    @Test func aiProviderMapsToExpectedKeychainAccount() {
        #expect(AIProvider.openAI.keychainAccount == KeychainKey.openAI.rawValue)
        #expect(AIProvider.anthropic.keychainAccount == KeychainKey.anthropic.rawValue)
    }

    @Test func aiProviderDisplayNamesAreVendorNames() {
        #expect(AIProvider.openAI.displayName == "OpenAI")
        #expect(AIProvider.anthropic.displayName == "Anthropic")
    }

    @Test func defaultProvidersIncludeOpenAICompatibleAndVendorAPIs() {
        #expect(AIProvider.openAI.kind == .openAICompatible)
        #expect(AIProvider.groq.kind == .openAICompatible)
        #expect(AIProvider.anthropic.kind == .anthropic)
        #expect(AIProvider.google.kind == .googleGemini)
    }

    @Test func onlyOpenAICompatibleAndElevenLabsProvidersSupportTranscription() {
        #expect(AIProvider.openAI.supportsTranscription)
        #expect(AIProvider.groq.supportsTranscription)
        #expect(AIProvider.elevenLabs.supportsTranscription)
        #expect(!AIProvider.anthropic.supportsTranscription)
        #expect(!AIProvider.google.supportsTranscription)
    }

    @Test func onlyElevenLabsIsExcludedFromSummarization() {
        // ElevenLabs is transcription-only; every other built-in provider
        // (including on-device) still summarizes.
        #expect(!AIProvider.elevenLabs.supportsSummarization)
        #expect(AIProvider.openAI.supportsSummarization)
        #expect(AIProvider.groq.supportsSummarization)
        #expect(AIProvider.anthropic.supportsSummarization)
        #expect(AIProvider.google.supportsSummarization)
        #expect(AIProvider.appleOnDevice.supportsSummarization)
    }

    @Test func defaultTranscriptionModelIsPerVendorWhisper() {
        #expect(AIProvider.openAI.defaultTranscriptionModel == "whisper-1")
        #expect(AIProvider.groq.defaultTranscriptionModel == "whisper-large-v3")
        #expect(AIProvider.elevenLabs.defaultTranscriptionModel == "scribe_v1")
    }

    @Test func elevenLabsFallbackModelsIsJustScribe() {
        #expect(AIProvider.elevenLabs.fallbackModels == ["scribe_v1"])
    }

    @Test func groqFallbackModelsIncludeBothWhisperVariants() {
        // Regression guard: Groq's cheaper/faster whisper-large-v3-turbo must
        // stay selectable in Settings even when the live /models fetch fails
        // and ProviderModelsService falls back to this static list.
        #expect(AIProvider.groq.fallbackModels.contains("whisper-large-v3"))
        #expect(AIProvider.groq.fallbackModels.contains("whisper-large-v3-turbo"))
    }

    @Test func transcriptionModelPickerWhisperFilterKeepsGroqTurboModel() {
        // Mirrors TranscriptionModelPicker's filter closure (SettingsProviderViews.swift):
        // narrows a provider's loaded model list to Whisper-family names.
        let whisperFilter: ([String]) -> [String] = { loaded in
            let whisperModels = loaded.filter { $0.localizedCaseInsensitiveContains("whisper") }
            return whisperModels.isEmpty ? loaded : whisperModels
        }
        let filtered = whisperFilter(AIProvider.groq.fallbackModels)
        #expect(filtered.contains("whisper-large-v3-turbo"))
        #expect(filtered.contains("whisper-large-v3"))
        #expect(!filtered.contains("llama-3.3-70b-versatile"))
    }

    @Test func appleOnDeviceIsABuiltInWithNoTranscriptionSupport() {
        #expect(AIProvider.appleOnDevice.kind == .appleOnDevice)
        #expect(AIProvider.appleOnDevice.isBuiltIn)
        #expect(!AIProvider.appleOnDevice.supportsTranscription)
        #expect(AIProvider.defaultProviders.contains(where: { $0.id == AIProvider.appleOnDevice.id }))
    }

    @Test func networkCasesExcludeAppleOnDevice() {
        #expect(!AIProviderKind.networkCases.contains(.appleOnDevice))
        #expect(AIProviderKind.networkCases.count == AIProviderKind.allCases.count - 1)
    }

    @Test func onlyElevenLabsSupportsNativeDiarization() {
        #expect(AIProvider.elevenLabs.supportsNativeDiarization)
        #expect(!AIProvider.openAI.supportsNativeDiarization)
        #expect(!AIProvider.groq.supportsNativeDiarization)
        #expect(!AIProvider.anthropic.supportsNativeDiarization)
        #expect(!AIProvider.google.supportsNativeDiarization)
        #expect(!AIProvider.appleOnDevice.supportsNativeDiarization)
    }

    // MARK: - TranscriptionMode

    @Test func transcriptionModeIdMatchesRawValue() {
        for mode in TranscriptionMode.allCases {
            #expect(mode.id == mode.rawValue)
        }
    }

    // MARK: - DiarizationEngine

    @Test func diarizationEngineIdMatchesRawValue() {
        for engine in DiarizationEngine.allCases {
            #expect(engine.id == engine.rawValue)
        }
    }

    @Test func transcriptionProviderNativeDiarizationNeedsNoModelDownload() {
        #expect(DiarizationEngine.transcriptionProviderNative.requiredModelSet == nil)
    }

    // MARK: - AudioQuality

    @Test func audioQualityIdMatchesRawValue() {
        for quality in AudioQuality.allCases {
            #expect(quality.id == quality.rawValue)
        }
    }

    /// The tiers must stay ordered high → low, and stay inside the range that is
    /// transparent for mono speech at the recorder's fixed storage sample rate.
    /// A tier above ~64 kbps there would be spending bits nothing can hear.
    @Test func audioQualityBitRatesDescendAndStayInSpeechRange() {
        #expect(AudioQuality.high.bitRate > AudioQuality.standard.bitRate)
        #expect(AudioQuality.standard.bitRate > AudioQuality.low.bitRate)
        for quality in AudioQuality.allCases {
            #expect(quality.bitRate >= 32_000)
            #expect(quality.bitRate <= 64_000)
        }
    }

    @Test(arguments: AudioQuality.allCases)
    func audioQualityBytesPerHourMatchesItsBitRate(quality: AudioQuality) {
        #expect(quality.approximateBytesPerHour == Int64(quality.bitRate) / 8 * 3600)
    }

    /// Sanity-check the number shown in Settings: the default tier has to land
    /// well under the ~58 MB/hour the app used to write at 128 kbps.
    @Test func defaultQualityCostsAboutTwentyMegabytesPerHour() {
        let megabytes = Double(AudioQuality.standard.approximateBytesPerHour) / 1_000_000
        #expect(megabytes > 20)
        #expect(megabytes < 23)
    }

    // MARK: - TranscriptSegment

    @Test func transcriptSegmentDurationIsClampedToZero() {
        let normal = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 1, endTime: 4, text: "hi")
        #expect(normal.duration == 3)

        let inverted = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 5, endTime: 2, text: "hi")
        #expect(inverted.duration == 0)
    }

    // MARK: - Highlight

    @Test func highlightRoundTripsThroughJSONEncoding() throws {
        let highlight = Highlight(timestamp: 12.5)
        let data = try JSONEncoder().encode(highlight)
        let decoded = try JSONDecoder().decode(Highlight.self, from: data)
        #expect(decoded == highlight)
    }

    @Test func highlightGetsAUniqueIDByDefault() {
        let first = Highlight(timestamp: 0)
        let second = Highlight(timestamp: 0)
        #expect(first.id != second.id)
    }
}
