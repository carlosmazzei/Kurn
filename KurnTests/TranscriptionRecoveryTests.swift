//
//  TranscriptionRecoveryTests.swift
//  KurnTests
//
//  The launch-time sweep resumes only stale runs proven to use an on-device
//  checkpoint. Cloud or unknown work requires manual retry because the process
//  may have died after a paid request completed remotely.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionRecoveryTests {

    private func makeRecording(
        in context: ModelContext,
        status: TranscriptionStatus,
        checkpointEngine: TranscriptionEngine? = nil
    ) -> Recording {
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID()).m4a", duration: 60)
        recording.transcriptionStatus = status
        if let checkpointEngine {
            recording.transcriptionCheckpoint = TranscriptionCheckpoint(
                engineRaw: checkpointEngine.rawValue,
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

    @Test func staleCloudCheckpointRequiresManualRetry() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(
            in: context,
            status: .inProgress,
            checkpointEngine: .whisperAPI
        )
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .failed)
        #expect(recording.transcriptionCheckpointData != nil)
    }

    @Test func staleOnDeviceCheckpointBecomesPending() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(
            in: context,
            status: .inProgress,
            checkpointEngine: .whisperCpp
        )
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .pending)
        #expect(recording.transcriptionCheckpointData != nil)
    }

    @Test func staleInProgressWithoutCheckpointRequiresManualRetry() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(in: context, status: .inProgress)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .failed)
    }

    @Test func staleCorruptedCheckpointRequiresManualRetry() throws {
        // A checkpoint that fails to decode or verify can't prove what engine
        // produced it, so it must never auto-resume — and the corrupted bytes
        // are preserved for diagnostics, not blanked.
        let container = TestModelContainer.make()
        let context = container.mainContext
        let recording = makeRecording(in: context, status: .inProgress, checkpointEngine: .whisperCpp)
        let garbage = Data([0x7B, 0x22, 0xFF, 0x00])
        recording.transcriptionCheckpointData = garbage
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(recording.transcriptionStatus == .failed)
        #expect(recording.transcriptionCheckpointData == garbage)
    }

    @Test func activeRecordingsAreExcludedFromSweep() throws {
        // The foreground sweep must not touch a run some view model in this
        // process is actually working on — only orphaned `.inProgress` rows.
        let container = TestModelContainer.make()
        let context = container.mainContext
        let active = makeRecording(in: context, status: .inProgress, checkpointEngine: .whisperCpp)
        let stale = makeRecording(in: context, status: .inProgress, checkpointEngine: .whisperCpp)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container, excluding: [active.id])

        #expect(active.transcriptionStatus == .inProgress)
        #expect(stale.transcriptionStatus == .pending)
    }

    @Test func otherStatusesAreLeftAlone() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let done = makeRecording(in: context, status: .done)
        let failed = makeRecording(in: context, status: .failed)
        let pending = makeRecording(in: context, status: .pending, checkpointEngine: .whisperCpp)
        let none = makeRecording(in: context, status: .none)
        try context.save()

        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        #expect(done.transcriptionStatus == .done)
        #expect(failed.transcriptionStatus == .failed)
        #expect(pending.transcriptionStatus == .pending)
        #expect(none.transcriptionStatus == .none)
    }

    @Test func onlyExplicitCancellationCanResumeAutomatically() {
        #expect(TranscriptionViewModel.isResumableCancellation(
            .networkError(URLError(.cancelled))
        ))
        #expect(!TranscriptionViewModel.isResumableCancellation(
            .networkError(URLError(.timedOut))
        ))
        #expect(!TranscriptionViewModel.isResumableCancellation(.ambiguousProviderResult))
    }
}
