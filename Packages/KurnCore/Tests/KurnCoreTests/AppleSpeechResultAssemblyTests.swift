//
//  AppleSpeechResultAssemblyTests.swift
//  KurnCoreTests
//
//  What one SpeechAnalyzer result becomes: a span per word when the timings
//  sit on the result's own timeline, the result-level span when they don't,
//  and nothing when the framework reports a time it cannot represent.
//

import Foundation
import Testing
@testable import KurnCore

struct AppleSpeechResultAssemblyTests {

    // MARK: - Spans

    @Test func wordsBecomeOneSpanEach() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [
                TimedWord(text: "vamos", start: 10, end: 10.4),
                TimedWord(text: "começar", start: 10.4, end: 11.0)
            ],
            text: "vamos começar",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(assembly.spans.map(\.text) == ["vamos", "começar"])
        #expect(assembly.spans.first?.start == 10)
        #expect(assembly.spans.last?.end == 11)
        #expect(!assembly.rejectedWordTimings)
    }

    @Test func noWordsFallsBackToTheResultSpan() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [], text: "vamos começar", resultStart: 10, resultEnd: 11, duration: 60
        )
        #expect(assembly.spans == [TranscribedSpan(text: "vamos começar", start: 10, end: 11)])
        #expect(!assembly.rejectedWordTimings)
    }

    /// The failure this guard exists for: timings on a different timeline than
    /// the result would read as a correct transcript with every word at the
    /// start of the recording, and speaker attribution would collapse onto
    /// whoever spoke first. Better to lose the granularity than the timeline.
    @Test func wordsOffTheResultTimelineAreRefused() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [
                TimedWord(text: "vamos", start: 0, end: 0.4),
                TimedWord(text: "começar", start: 0.4, end: 1.0)
            ],
            text: "vamos começar",
            resultStart: 600,
            resultEnd: 601,
            duration: 3600
        )
        #expect(assembly.spans == [TranscribedSpan(text: "vamos começar", start: 600, end: 601)])
        #expect(assembly.rejectedWordTimings)
    }

    @Test func wordsRunningPastTheResultAreRefused() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [TimedWord(text: "vamos", start: 10, end: 45)],
            text: "vamos",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(assembly.spans.count == 1)
        #expect(assembly.spans.first?.end == 11)
        #expect(assembly.rejectedWordTimings)
    }

    @Test func wordsWithinTheToleranceAreKept() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [TimedWord(text: "vamos", start: 9.5, end: 11.8)],
            text: "vamos",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(assembly.spans == [TranscribedSpan(text: "vamos", start: 9.5, end: 11.8)])
        #expect(!assembly.rejectedWordTimings)
    }

    @Test func wordsTheBuilderDropsFallBackToTheResultSpan() {
        let assembly = AppleSpeechResultAssembly.assemble(
            words: [TimedWord(text: "  ", start: 10, end: 10.5)],
            text: "vamos",
            resultStart: 10,
            resultEnd: 11,
            duration: 60
        )
        #expect(assembly.spans == [TranscribedSpan(text: "vamos", start: 10, end: 11)])
    }

    // MARK: - Bounds and words

    @Test func resultBoundsRejectNonFiniteTimes() {
        #expect(AppleSpeechResultAssembly.resultBounds(start: .nan, duration: 1) == nil)
        #expect(AppleSpeechResultAssembly.resultBounds(start: 1, duration: .infinity) == nil)
        let bounds = AppleSpeechResultAssembly.resultBounds(start: 4, duration: 2.5)
        #expect(bounds?.start == 4)
        #expect(bounds?.end == 6.5)
    }

    @Test func resultBoundsAreNeverNegative() {
        let bounds = AppleSpeechResultAssembly.resultBounds(start: -2, duration: 1)
        #expect(bounds?.start == 0)
        #expect(bounds?.end == 0)
    }

    @Test func wordsAreTrimmedAndValidated() {
        #expect(AppleSpeechResultAssembly.word(text: " olá ", start: 1, end: 2)
                == TimedWord(text: "olá", start: 1, end: 2))
        #expect(AppleSpeechResultAssembly.word(text: "   ", start: 1, end: 2) == nil)
        #expect(AppleSpeechResultAssembly.word(text: "olá", start: 2, end: 2) == nil)
        #expect(AppleSpeechResultAssembly.word(text: "olá", start: .nan, end: 2) == nil)
        #expect(AppleSpeechResultAssembly.word(text: "olá", start: -1, end: 0.5)
                == TimedWord(text: "olá", start: 0, end: 0.5))
    }

    // MARK: - Progress and completion

    @Test func progressIsHeldBelowOneUntilTheAnalyzerFinishes() {
        #expect(AppleSpeechResultAssembly.progress(resultEnd: 30, duration: 60) == 0.5)
        #expect(AppleSpeechResultAssembly.progress(resultEnd: 60, duration: 60) == 0.99)
        #expect(AppleSpeechResultAssembly.progress(resultEnd: -5, duration: 60) == 0)
        #expect(AppleSpeechResultAssembly.progress(resultEnd: 5, duration: 0) == nil)
    }

    @Test func finishedSortsAndReportsNoSpeech() {
        #expect(AppleSpeechResultAssembly.finished([]) == nil)
        let spans = [
            TranscribedSpan(text: "b", start: 5, end: 6),
            TranscribedSpan(text: "a", start: 1, end: 2)
        ]
        #expect(AppleSpeechResultAssembly.finished(spans)?.map(\.text) == ["a", "b"])
    }
}
