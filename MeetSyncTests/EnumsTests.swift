//
//  EnumsTests.swift
//  MeetSyncTests
//

import Testing
@testable import MeetSync

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

    // MARK: - TranscriptionMode

    @Test func transcriptionModeIdMatchesRawValue() {
        for mode in TranscriptionMode.allCases {
            #expect(mode.id == mode.rawValue)
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
