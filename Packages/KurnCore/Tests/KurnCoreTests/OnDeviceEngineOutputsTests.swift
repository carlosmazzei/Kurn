//
//  OnDeviceEngineOutputsTests.swift
//  KurnCoreTests
//
//  What the FluidAudio VAD and batch ASR adapters hand back: speech regions
//  that are never empty, a progress session only where the engine runs one,
//  and a transcript built from word timings or, without them, the whole clip.
//  `CoalescedLoader` is the shared-model cache behind the ASR adapter.
//

import Foundation
import Testing
@testable import KurnCore

struct SpeechRegionNormalizationTests {

    @Test func keepsValidRegionsInOrder() {
        let raw = [SpeechRegion(start: 1, end: 2), SpeechRegion(start: 3, end: 5)]
        #expect(SpeechRegionNormalization.regions(raw, clipDuration: 10) == raw)
    }

    @Test func dropsEmptyAndInvertedRegions() {
        let raw = [
            SpeechRegion(start: 1, end: 1),
            SpeechRegion(start: 4, end: 3),
            SpeechRegion(start: 5, end: 6)
        ]
        #expect(SpeechRegionNormalization.regions(raw, clipDuration: 10) == [SpeechRegion(start: 5, end: 6)])
    }

    @Test func noSpeechFallsBackToTheWholeClip() {
        #expect(SpeechRegionNormalization.regions([], clipDuration: 7.5) == [SpeechRegion(start: 0, end: 7.5)])
        #expect(SpeechRegionNormalization.regions([SpeechRegion(start: 2, end: 2)], clipDuration: 3)
                == [SpeechRegion(start: 0, end: 3)])
    }

    @Test func wholeClipNeverHasANegativeEnd() {
        #expect(SpeechRegionNormalization.wholeClip(duration: -1) == SpeechRegion(start: 0, end: 0))
        #expect(SpeechRegionNormalization.wholeClip(duration: 0) == SpeechRegion(start: 0, end: 0))
    }
}

struct BatchTranscriptAssemblyTests {

    @Test func progressOnlyAboveTheEngineChunkThreshold() {
        #expect(!BatchTranscriptAssembly.reportsProgress(forDuration: 0))
        #expect(!BatchTranscriptAssembly.reportsProgress(forDuration: 15.5))
        #expect(BatchTranscriptAssembly.reportsProgress(forDuration: 15.6))
        #expect(BatchTranscriptAssembly.reportsProgress(forDuration: 3_600))
    }

    @Test func fractionsAreClampedToUnitRange() {
        #expect(BatchTranscriptAssembly.clampedFraction(-0.2) == 0)
        #expect(BatchTranscriptAssembly.clampedFraction(0.4) == 0.4)
        #expect(BatchTranscriptAssembly.clampedFraction(1.3) == 1)
    }

    @Test func blankTextGivesAnEmptyTranscript() {
        let words = [TimedWord(text: "ghost", start: 0, end: 1)]
        let transcript = BatchTranscriptAssembly.transcript(text: " \n\t", words: words, duration: 5)
        #expect(transcript.spans.isEmpty)
        #expect(transcript.language.isEmpty)
        #expect(transcript.speakerTurns == nil)
    }

    @Test func wordTimingsBecomeOneSpanPerWord() {
        let words = [
            TimedWord(text: "hello", start: 0.2, end: 0.6),
            TimedWord(text: "world", start: 0.7, end: 1.1)
        ]
        let transcript = BatchTranscriptAssembly.transcript(text: "hello world", words: words, duration: 2)
        #expect(transcript.spans == [
            TranscribedSpan(text: "hello", start: 0.2, end: 0.6),
            TranscribedSpan(text: "world", start: 0.7, end: 1.1)
        ])
        #expect(transcript.language.isEmpty)
    }

    @Test func withoutTimingsTheTrimmedTextSpansTheClip() {
        let transcript = BatchTranscriptAssembly.transcript(text: "  hello world \n", words: [], duration: 4)
        #expect(transcript.spans == [TranscribedSpan(text: "hello world", start: 0, end: 4)])
    }
}

struct CoalescedLoaderTests {

    private actor Counter {
        var calls = 0
        func increment() -> Int {
            calls += 1
            return calls
        }
    }

    private struct LoadFailed: Error {}

    @Test func loadsOnceAndKeepsTheValue() async throws {
        let loader = CoalescedLoader<Int>()
        let counter = Counter()
        #expect(await loader.current == nil)
        let first = try await loader.value { await counter.increment() }
        let second = try await loader.value { await counter.increment() }
        #expect(first == 1)
        #expect(second == 1)
        #expect(await counter.calls == 1)
        #expect(await loader.current == 1)
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let loader = CoalescedLoader<Int>()
        let counter = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await loader.value {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return await counter.increment()
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == Array(repeating: 1, count: 8))
        #expect(await counter.calls == 1)
    }

    @Test func failureIsNotCachedAndTheNextCallRetries() async throws {
        let loader = CoalescedLoader<Int>()
        let counter = Counter()
        await #expect(throws: LoadFailed.self) {
            try await loader.value {
                _ = await counter.increment()
                throw LoadFailed()
            }
        }
        #expect(await loader.current == nil)
        let value = try await loader.value { await counter.increment() }
        #expect(value == 2)
        #expect(await loader.current == 2)
    }
}
