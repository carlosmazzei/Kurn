//
//  MeetingLanguageTests.swift
//  KurnCoreTests
//
//  `MeetingLanguage` raw values are persisted in `Meeting.languageRaw`, and
//  its Whisper codes go over the wire, so the table is the contract: every
//  case has an entry, codes are unique, and a detected code maps back to the
//  case it came from.
//

import Foundation
import Testing
@testable import KurnCore

struct MeetingLanguageTests {

    @Test func everyCaseHasATableEntry() {
        for language in MeetingLanguage.allCases {
            #expect(!language.displayName.isEmpty)
            #expect(language.id == language.rawValue)
            if language == .autoDetect {
                #expect(language.whisperCode == nil)
                #expect(language.localeIdentifier == nil)
            } else {
                #expect(language.whisperCode?.isEmpty == false, "\(language) has a Whisper code")
                #expect(language.localeIdentifier?.isEmpty == false, "\(language) has a locale")
            }
        }
    }

    @Test func whisperCodesAreUnique() {
        let codes = MeetingLanguage.allCases.compactMap(\.whisperCode)
        #expect(Set(codes).count == codes.count)
    }

    @Test func persistedRawValuesAreStable() {
        // Renaming a case would orphan every stored `Meeting.languageRaw`.
        #expect(MeetingLanguage(rawValue: "autoDetect") == .autoDetect)
        #expect(MeetingLanguage(rawValue: "portuguese") == .portuguese)
        #expect(MeetingLanguage(rawValue: "english") == .english)
        #expect(MeetingLanguage(rawValue: "cantonese") == .cantonese)
    }

    @Test func primaryLocalesUseRegionalIdentifiers() {
        #expect(MeetingLanguage.portuguese.localeIdentifier == "pt-BR")
        #expect(MeetingLanguage.english.localeIdentifier == "en-US")
        #expect(MeetingLanguage.chinese.whisperCode == "zh")
    }

    @Test func everyWhisperCodeRoundTrips() {
        for language in MeetingLanguage.allCases {
            guard let code = language.whisperCode else { continue }
            #expect(MeetingLanguage(detectedCode: code) == language, "\(code) maps back to \(language)")
        }
    }

    @Test func detectedCodesAreCaseInsensitive() {
        #expect(MeetingLanguage(detectedCode: "PT") == .portuguese)
        #expect(MeetingLanguage(detectedCode: "Haw") == .hawaiian)
    }

    @Test func regionalTagsFallBackToTheirLanguage() {
        #expect(MeetingLanguage(detectedCode: "pt-BR") == .portuguese)
        #expect(MeetingLanguage(detectedCode: "en_GB") == .english)
    }

    @Test func rawValueNamesAreAccepted() {
        #expect(MeetingLanguage(detectedCode: "Spanish") == .spanish)
    }

    @Test func unknownCodesFallBackToAutoDetect() {
        #expect(MeetingLanguage(detectedCode: "xx") == .autoDetect)
        #expect(MeetingLanguage(detectedCode: "") == .autoDetect)
    }

    @Test func codableUsesTheRawValue() throws {
        let data = try JSONEncoder().encode([MeetingLanguage.german])
        #expect(String(data: data, encoding: .utf8) == "[\"german\"]")
        let decoded = try JSONDecoder().decode([MeetingLanguage].self, from: data)
        #expect(decoded == [.german])
    }
}
