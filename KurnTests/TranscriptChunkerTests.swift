//
//  TranscriptChunkerTests.swift
//  KurnTests
//
//  Pure tests for the transcript windowing that feeds the semantic index:
//  passage sizing, absolute-timestamp offsetting, and dominant-speaker
//  attribution. No SwiftData, no embedder.
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptChunkerTests {

    private func segment(_ text: String, _ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: speaker, startTime: start, endTime: end, text: text)
    }

    @Test func emptyInputProducesNoChunks() {
        #expect(TranscriptChunker.chunk([]).isEmpty)
    }

    @Test func shortConversationMergesIntoOnePassage() {
        let rec = UUID()
        let input = TranscriptChunker.Input(recordingID: rec, offset: 0, segments: [
            segment("Hello there.", "Speaker 1", 0, 2),
            segment("Hi, how are you?", "Speaker 2", 2, 4)
        ])
        let chunks = TranscriptChunker.chunk([input])
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("Hello there."))
        #expect(chunks[0].text.contains("how are you"))
        #expect(chunks[0].startTime == 0)
        #expect(chunks[0].endTime == 4)
    }

    @Test func offsetIsAppliedToAbsoluteTimestamps() {
        let rec = UUID()
        let input = TranscriptChunker.Input(recordingID: rec, offset: 100, segments: [
            segment("First recording already ran.", "Speaker 1", 5, 8)
        ])
        let chunks = TranscriptChunker.chunk([input])
        #expect(chunks.count == 1)
        #expect(chunks[0].startTime == 105)
        #expect(chunks[0].endTime == 108)
        #expect(chunks[0].recordingID == rec)
    }

    @Test func longMonologueSplitsAtTargetSize() {
        let rec = UUID()
        // A single speaker producing well over the target character budget in
        // several segments should yield more than one passage.
        let line = String(repeating: "word ", count: 40) // ~200 chars each
        let segments = (0..<6).map { i in
            segment(line, "Speaker 1", TimeInterval(i), TimeInterval(i) + 1)
        }
        let chunks = TranscriptChunker.chunk([TranscriptChunker.Input(recordingID: rec, offset: 0, segments: segments)])
        #expect(chunks.count > 1)
    }

    @Test func dominantSpeakerIsTheOneWithMostText() {
        let rec = UUID()
        let input = TranscriptChunker.Input(recordingID: rec, offset: 0, segments: [
            segment("Ok.", "Speaker 2", 0, 1),
            segment(String(repeating: "lots of talking here ", count: 20), "Speaker 1", 1, 10)
        ])
        let chunks = TranscriptChunker.chunk([input])
        #expect(chunks.first?.speakerLabel == "Speaker 1")
    }

    @Test func emptySegmentsAreSkipped() {
        let rec = UUID()
        let input = TranscriptChunker.Input(recordingID: rec, offset: 0, segments: [
            segment("   ", "Speaker 1", 0, 1),
            segment("real content", "Speaker 1", 1, 2)
        ])
        let chunks = TranscriptChunker.chunk([input])
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "real content")
    }
}
