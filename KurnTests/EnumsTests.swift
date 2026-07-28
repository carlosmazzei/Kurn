//
//  EnumsTests.swift
//  KurnTests
//

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

    @Test func onlyOpenAICompatibleProvidersSupportTranscription() {
        #expect(AIProvider.openAI.supportsTranscription)
        #expect(AIProvider.groq.supportsTranscription)
        #expect(!AIProvider.anthropic.supportsTranscription)
        #expect(!AIProvider.google.supportsTranscription)
    }

    @Test func defaultTranscriptionModelIsPerVendorWhisper() {
        #expect(AIProvider.openAI.defaultTranscriptionModel == "whisper-1")
        #expect(AIProvider.groq.defaultTranscriptionModel == "whisper-large-v3")
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
}
