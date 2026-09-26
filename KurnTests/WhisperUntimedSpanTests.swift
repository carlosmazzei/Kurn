//
//  WhisperUntimedSpanTests.swift
//  KurnTests
//
//  `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` return plain text with no
//  timing, which `OpenAIProvider` surfaces as one `start: 0, end: 0` span per
//  chunk. Left like that, a whole chunk's text sat on a single instant and was
//  attributed to one speaker — the public-dataset harness measured 100% DER on
//  AMI for both models. These pin the fix: the span takes the chunk's extent,
//  and nothing else about the transcript changes.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct WhisperUntimedSpanTests {

    @Test func anUntimedSpanCoversTheWholeChunk() {
        let raw = RawTranscript(
            spans: [TranscribedSpan(text: "hello there", start: 0, end: 0)],
            language: "en"
        )
        let spread = WhisperTranscriber.spreadingUntimedSpans(raw, across: 300)

        #expect(spread.spans.count == 1)
        #expect(spread.spans[0].start == 0)
        #expect(spread.spans[0].end == 300)
        #expect(spread.spans[0].text == "hello there")
        #expect(spread.language == "en")
    }

    @Test func severalUntimedSpansSplitTheChunkInOrder() {
        let raw = RawTranscript(
            spans: [
                TranscribedSpan(text: "a", start: 0, end: 0),
                TranscribedSpan(text: "b", start: 0, end: 0)
            ],
            language: ""
        )
        let spread = WhisperTranscriber.spreadingUntimedSpans(raw, across: 10)

        #expect(spread.spans.map(\.text) == ["a", "b"])
        #expect(spread.spans.map(\.start) == [0, 5])
        #expect(spread.spans.map(\.end) == [5, 10])
    }

    @Test func timedSpansAndUnknownDurationsAreLeftAlone() {
        let timed = RawTranscript(
            spans: [TranscribedSpan(text: "a", start: 1, end: 2)],
            language: ""
        )
        #expect(!WhisperTranscriber.hasOnlyUntimedSpans(timed))
        #expect(WhisperTranscriber.spreadingUntimedSpans(timed, across: 10).spans[0].end == 2)

        let untimed = RawTranscript(spans: [TranscribedSpan(text: "a", start: 0, end: 0)], language: "")
        #expect(WhisperTranscriber.spreadingUntimedSpans(untimed, across: 0).spans[0].end == 0)
        #expect(!WhisperTranscriber.hasOnlyUntimedSpans(RawTranscript(spans: [], language: "")))
    }
}
