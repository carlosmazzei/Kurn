//
//  SemanticChunkTests.swift
//  KurnTests
//
//  Exercises the `SemanticChunk` model against a real in-memory
//  `ModelContainer`: the meeting inverse relationship, cascade delete, and the
//  vector accessor. The chunk lives in the same store transcripts/summaries do,
//  which `ModelStoreProtection` encrypts at rest (asserted separately in
//  `ModelStoreProtectionTests`), so there is no plaintext sidecar to leak.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SemanticChunkTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func insertingChunkPopulatesMeetingInverse() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let chunk = SemanticChunk(
            meeting: meeting, recordingID: UUID(), text: "hello",
            startTime: 0, endTime: 2, speakerLabel: "Speaker 1",
            vector: [0.1, 0.2, 0.3], modelIdentifier: "test-v1"
        )
        context.insert(chunk)
        try context.save()

        #expect(meeting.semanticChunks.count == 1)
        #expect(meeting.semanticChunks.first?.text == "hello")
        #expect(meeting.semanticChunks.first?.dimension == 3)
    }

    @Test func deletingMeetingCascadesToChunks() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        context.insert(SemanticChunk(
            meeting: meeting, recordingID: UUID(), text: "a",
            startTime: 0, endTime: 1, speakerLabel: "S1",
            vector: [1, 0], modelIdentifier: "test-v1"
        ))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SemanticChunk>()) == 1)

        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SemanticChunk>()) == 0)
    }

    @Test func vectorAccessorRoundTrips() {
        let chunk = SemanticChunk(
            recordingID: UUID(), text: "x", startTime: 0, endTime: 1,
            speakerLabel: "S1", vector: [0.25, -0.5, 0.75], modelIdentifier: "test-v1"
        )
        let decoded = chunk.vector
        #expect(decoded.count == 3)
        #expect(abs(decoded[1] + 0.5) < 0.0001)
    }

    @Test func searchCandidateSnapshotsFields() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let chunk = SemanticChunk(
            meeting: meeting, recordingID: UUID(), text: "snapshot me",
            startTime: 5, endTime: 8, speakerLabel: "Speaker 2",
            vector: [1, 0], modelIdentifier: "test-v1"
        )
        context.insert(chunk)
        try context.save()

        let candidate = chunk.searchCandidate
        #expect(candidate.text == "snapshot me")
        #expect(candidate.start == 5)
        #expect(candidate.speakerLabel == "Speaker 2")
        #expect(candidate.meetingID == meeting.id)
        #expect(candidate.vector.count == 2)
    }
}
