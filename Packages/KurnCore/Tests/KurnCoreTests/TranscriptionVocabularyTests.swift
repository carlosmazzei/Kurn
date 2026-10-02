//
//  TranscriptionVocabularyTests.swift
//  KurnCoreTests
//
//  The small closed vocabularies a transcript is stored with: the engine,
//  the storage mode it maps to, the status, and the segment value type.
//  Raw values are persisted, so they are pinned here.
//

import Foundation
import Testing
@testable import KurnCore

struct TranscriptionVocabularyTests {

    @Test func onlyTheCloudEngineIsCloudTranscription() {
        for engine in TranscriptionEngine.allCases {
            #expect(engine.isCloudTranscription == (engine == .whisperAPI))
            #expect(engine.storageMode == (engine == .whisperAPI ? TranscriptionMode.whisperAPI : TranscriptionMode.onDevice))
            #expect(!engine.displayName.isEmpty)
            #expect(engine.id == engine.rawValue)
        }
    }

    @Test func engineRawValuesAreStable() {
        #expect(TranscriptionEngine.allCases.map(\.rawValue) == ["appleSpeech", "fluidAudioParakeet", "whisperAPI", "whisperCpp"])
    }

    @Test func modesAndStatusesHaveDisplayNames() {
        for mode in TranscriptionMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(mode.id == mode.rawValue)
        }
        for status in TranscriptionStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(status.id == status.rawValue)
        }
        #expect(TranscriptionStatus.allCases.map(\.rawValue) == ["none", "inProgress", "pending", "done", "failed"])
    }

    @Test func segmentDurationIsNeverNegative() {
        let forward = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 2, endTime: 5.5, text: "hi")
        #expect(forward.duration == 3.5)
        let inverted = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 5, endTime: 4, text: "hi")
        #expect(inverted.duration == 0)
        #expect(forward.confidence == nil)
    }

    @Test func segmentRoundTripsThroughJSON() throws {
        let segment = TranscriptSegment(speakerLabel: "Ana", startTime: 1, endTime: 2, text: "olá", confidence: 0.9)
        let data = try JSONEncoder().encode(segment)
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: data) == segment)
    }

    @Test func timelineValueTypesKeepTheirFields() {
        let region = SpeechRegion(start: 1, end: 2)
        #expect(region.start == 1 && region.end == 2)
        let segment = TimelineSegment(compactedStart: 0, originalStart: 10, duration: 3)
        #expect(segment == TimelineSegment(compactedStart: 0, originalStart: 10, duration: 3))
        #expect(AppLifecyclePhase.active != .background)
    }
}
