//
//  TranscriptionRecoveryTests.swift
//  KurnTests
//
//  The launch-time sweep turns recordings a dead process left at `.inProgress`
//  into `.pending` (checkpoint saved — resumable) or `.failed` (nothing to
//  resume), and must leave every other status untouched.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionRecoveryTests {

    private func makeRecording(
        in context: ModelContext,
        status: TranscriptionStatus,
        withCheckpoint: Bool = false
    ) -> Recording {
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID()).m4a", duration: 60)
        recording.transcriptionStatus = status
        if withCheckpoint {
            recording.transcriptionCheckpoint = TranscriptionCheckpoint(
                engineRaw: TranscriptionEngine.whisperAPI.rawValue,
                languageRaw: MeetingLanguage.english.rawValue,
                compacted: false,
                totalChunks: 4,
                completedChunks: 2,
                detectedLanguage: "en",
                spans: []
            )
        }
        context.insert(recording)
        return recording
    }

    @Test func staleInProgressWithCheckpointBecomesPending() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(in: context, status: .inProgress, withCheckpoint: true)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .pending)
        #expect(recording.transcriptionCheckpointData != nil)
    }

    @Test func staleInProgressWithoutCheckpointBecomesFailed() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(in: context, status: .inProgress)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .failed)
    }

    @Test func otherStatusesAreLeftAlone() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let done = makeRecording(in: context, status: .done)
        let failed = makeRecording(in: context, status: .failed)
        let pending = makeRecording(in: context, status: .pending, withCheckpoint: true)
        let none = makeRecording(in: context, status: .none)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(done.transcriptionStatus == .done)
        #expect(failed.transcriptionStatus == .failed)
        #expect(pending.transcriptionStatus == .pending)
        #expect(none.transcriptionStatus == .none)
    }
}
