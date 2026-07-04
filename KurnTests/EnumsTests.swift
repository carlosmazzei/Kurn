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

    @Test(arguments: [
        (MeetingLanguage.portuguese, "pt-BR", "pt"),
        (MeetingLanguage.english, "en-US", "en"),
        (MeetingLanguage.spanish, "es-ES", "es"),
        (MeetingLanguage.french, "fr-FR", "fr"),
        (MeetingLanguage.german, "de-DE", "de"),
        (MeetingLanguage.japanese, "ja-JP", "ja"),
        (MeetingLanguage.chinese, "zh-CN", "zh")
    ])
    func localeAndWhisperCodeMatchExpected(language: MeetingLanguage, locale: String, whisperCode: String) {
        #expect(language.localeIdentifier == locale)
        #expect(language.whisperCode == whisperCode)
    }

    @Test func rawValueRoundTripsForAllCases() {
        for language in MeetingLanguage.allCases {
            #expect(MeetingLanguage(rawValue: language.rawValue) == language)
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

    // MARK: - TranscriptSegment

    @Test func transcriptSegmentDurationIsClampedToZero() {
        let normal = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 1, endTime: 4, text: "hi")
        #expect(normal.duration == 3)

        let inverted = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 5, endTime: 2, text: "hi")
        #expect(inverted.duration == 0)
    }
}
