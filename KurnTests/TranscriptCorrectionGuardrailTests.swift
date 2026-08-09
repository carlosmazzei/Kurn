//
//  TranscriptCorrectionGuardrailTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptCorrectionGuardrailTests {

    @Test func identicalTextIsAccepted() {
        #expect(TranscriptCorrectionGuardrail.accepts(original: "hello world", corrected: "hello world"))
    }

    @Test func identicalAfterTrimmingIsAccepted() {
        #expect(TranscriptCorrectionGuardrail.accepts(original: "hello world", corrected: "  hello world  "))
    }

    @Test func emptyingANonEmptySegmentIsRejected() {
        #expect(!TranscriptCorrectionGuardrail.accepts(original: "hello world", corrected: ""))
    }

    @Test func fabricatingTextFromAnEmptySegmentIsRejected() {
        #expect(!TranscriptCorrectionGuardrail.accepts(original: "", corrected: "hello world"))
    }

    @Test func smallSpellingAndPunctuationFixIsAccepted() {
        #expect(TranscriptCorrectionGuardrail.accepts(
            original: "we ned to ship this fetur",
            corrected: "We need to ship this feature."
        ))
    }

    @Test func wholesaleRewriteIsRejectedByWordRatio() {
        #expect(!TranscriptCorrectionGuardrail.accepts(
            original: "the quarterly numbers are looking strong across every region",
            corrected: "In summary, revenue grew significantly this quarter worldwide"
        ))
    }

    @Test func farTooShortReplacementIsRejectedByLengthRatio() {
        #expect(!TranscriptCorrectionGuardrail.accepts(
            original: "the quarterly numbers are looking strong across every region this year",
            corrected: "numbers strong"
        ))
    }

    @Test func farTooLongReplacementIsRejectedByLengthRatio() {
        #expect(!TranscriptCorrectionGuardrail.accepts(
            original: "ship it",
            corrected: "ship it today and then follow up with everyone about the release notes tomorrow"
        ))
    }

    @Test func unsegmentedScriptFallsBackToCharacterLevelDistance() {
        // A single-character homophone-style fix on a script with no
        // whitespace word boundaries (e.g. zh-Hans) should still be accepted.
        #expect(TranscriptCorrectionGuardrail.accepts(original: "我们今天开会", corrected: "我们今天开会了"))
        // But a wholesale rewrite of the same kind of input is still rejected.
        #expect(!TranscriptCorrectionGuardrail.accepts(original: "我们今天开会", corrected: "明天不下雨真好"))
    }
}
