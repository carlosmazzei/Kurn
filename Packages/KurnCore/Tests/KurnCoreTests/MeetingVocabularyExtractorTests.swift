//
//  MeetingVocabularyExtractorTests.swift
//  KurnCoreTests
//

import Foundation
import Testing
@testable import KurnCore

struct MeetingVocabularyExtractorTests {

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: text, confidence: nil)
    }

    @Test func repeatedProperNounIsExtracted() {
        let segments = [
            segment("let's ask Alice about it"),
            segment("I saw Alice yesterday")
        ]
        #expect(MeetingVocabularyExtractor.extract(from: segments).contains("Alice"))
    }

    @Test func singleOccurrenceWordIsNotExtracted() {
        let segments = [
            segment("we called Bob today"),
            segment("no other mention here")
        ]
        #expect(!MeetingVocabularyExtractor.extract(from: segments).contains("Bob"))
    }

    @Test func sentenceInitialCapitalizationAloneDoesNotCount() {
        let segments = [
            segment("The meeting starts now."),
            segment("The report is ready.")
        ]
        #expect(!MeetingVocabularyExtractor.extract(from: segments).contains("The"))
    }

    @Test func acronymIsExtracted() {
        let segments = [
            segment("check the API docs"),
            segment("the API works well")
        ]
        #expect(MeetingVocabularyExtractor.extract(from: segments).contains("API"))
    }

    @Test func extractionIsDeterministicAcrossRepeatedCalls() {
        let segments = [
            segment("let's ask Alice and Bob about Q3"),
            segment("Alice and Bob both agreed on Q3"),
            segment("the API and Q3 numbers matched")
        ]
        let first = MeetingVocabularyExtractor.extract(from: segments)
        let second = MeetingVocabularyExtractor.extract(from: segments)
        #expect(first == second)
    }

    @Test func extractionIsCappedAtMaxTerms() {
        var segments: [TranscriptSegment] = []
        for index in 0..<(MeetingVocabularyExtractor.maxTerms + 10) {
            let term = "Term\(index)9"
            segments.append(segment("mentioning \(term) here"))
            segments.append(segment("again \(term) came up"))
        }
        let extracted = MeetingVocabularyExtractor.extract(from: segments)
        #expect(extracted.count == MeetingVocabularyExtractor.maxTerms)
    }
}
