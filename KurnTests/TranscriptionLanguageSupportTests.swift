//
//  TranscriptionLanguageSupportTests.swift
//  KurnTests
//

import Testing
@testable import Kurn

struct TranscriptionLanguageSupportTests {

    @Test func whisperAPISupportsEveryLanguage() {
        for language in MeetingLanguage.allCases {
            #expect(TranscriptionLanguageSupport.isSupported(language, by: .whisperAPI))
        }
    }

    @Test func autoDetectIsSupportedByEveryEngine() {
        for engine in TranscriptionEngine.allCases {
            #expect(TranscriptionLanguageSupport.isSupported(.autoDetect, by: engine))
        }
    }

    @Test func fluidAudioSupportsExactlyItsDocumentedTwentyFiveLanguages() {
        let supported = MeetingLanguage.allCases.filter {
            TranscriptionLanguageSupport.isSupported($0, by: .fluidAudioParakeet)
        }
        // 25 languages + autoDetect.
        #expect(supported.count == 26)
        #expect(supported.contains(.english))
        #expect(supported.contains(.portuguese))
        #expect(!supported.contains(.japanese))
        #expect(!supported.contains(.swahili))
    }

    @Test func appleSpeechCheckDoesNotCrash() {
        for language in MeetingLanguage.allCases {
            _ = TranscriptionLanguageSupport.isSupported(language, by: .appleSpeech)
        }
    }
}
