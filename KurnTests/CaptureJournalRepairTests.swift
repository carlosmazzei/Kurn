//
//  CaptureJournalRepairTests.swift
//  KurnTests
//
//  Fault injection for a capture killed mid-recording: the `.m4a` on disk is
//  bytes with no container, and the ADTS journal beside it — possibly cut off
//  mid-frame, as a SIGKILL leaves it — is the only decodable copy. These run
//  the real remux (`exportToM4A`) unless a test is about the export failing.
//
//  "Untouched" is asserted as "still not decodable" rather than byte-equal:
//  another suite's orphan sweep may quarantine a row-less fixture from the
//  shared recordings directory while one of these tests is suspended.
//

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct CaptureJournalRepairTests {

    private struct ExportFailed: Error {}

    private static func recordingURL(_ fileName: String) -> URL {
        AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
    }

    /// The state a SIGKILL mid-recording leaves: an undecodable `.m4a` and a
    /// journal whose last frame was cut short.
    private static func makeKilledCapture(seconds: Double = 2) throws -> String {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.undecodableM4A(at: recordingURL(fileName))
        let journalURL = try AudioFixtures.adtsTone(seconds: seconds, at: CaptureJournal.url(for: fileName))
        let handle = try FileHandle(forWritingTo: journalURL)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 37)
        try handle.close()
        return fileName
    }

    private static func duration(of fileName: String) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: AudioFileStore.resolveURL(fileName: fileName))
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - CaptureJournalRepair.rebuild

    @Test func rebuildsAnUndecodableRecordingFromATruncatedJournal() async throws {
        let fileName = try Self.makeKilledCapture(seconds: 2)
        defer { AudioFileStore.delete(fileName: fileName) }
        #expect(!CaptureJournalRepair.isReadable(Self.recordingURL(fileName)))

        let outcome = await CaptureJournalRepair.rebuild(fileName: fileName)

        #expect(outcome == .rebuilt)
        #expect(CaptureJournalRepair.isReadable(Self.recordingURL(fileName)))
        #expect(try Self.duration(of: fileName) > 1.8)
        // Kept until the finalizer accepts the rebuilt file.
        #expect(CaptureJournal.exists(for: fileName))
    }

    @Test func rebuildsARecordingWhoseFileNeverAppeared() async throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.adtsTone(seconds: 1, at: CaptureJournal.url(for: fileName))
        defer { AudioFileStore.delete(fileName: fileName) }

        let outcome = await CaptureJournalRepair.rebuild(fileName: fileName)

        #expect(outcome == .rebuilt)
        #expect(CaptureJournalRepair.isReadable(Self.recordingURL(fileName)))
    }

    @Test func withoutAJournalThereIsNothingToRebuild() async {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        #expect(await CaptureJournalRepair.rebuild(fileName: fileName) == .noJournal)
    }

    @Test func aReadableRecordingIsNeverReplaced() async throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.m4aTone(seconds: 1, at: Self.recordingURL(fileName))
        try AudioFixtures.adtsTone(seconds: 3, at: CaptureJournal.url(for: fileName))
        defer { AudioFileStore.delete(fileName: fileName) }
        let original = try Data(contentsOf: Self.recordingURL(fileName))

        let outcome = await CaptureJournalRepair.rebuild(fileName: fileName) { _, _ in
            Issue.record("a readable recording must not be re-exported")
        }

        #expect(outcome == .notNeeded)
        #expect(try Data(contentsOf: Self.recordingURL(fileName)) == original)
    }

    @Test func aFailedExportLeavesBothFilesUntouched() async throws {
        let fileName = try Self.makeKilledCapture()
        defer { AudioFileStore.delete(fileName: fileName) }

        let outcome = await CaptureJournalRepair.rebuild(fileName: fileName) { _, _ in throw ExportFailed() }

        #expect(outcome == .failed)
        #expect(!CaptureJournalRepair.isReadable(Self.recordingURL(fileName)))
        #expect(CaptureJournal.exists(for: fileName))
    }

    @Test func anUndecodableExportIsRejected() async throws {
        let fileName = try Self.makeKilledCapture()
        defer { AudioFileStore.delete(fileName: fileName) }

        let outcome = await CaptureJournalRepair.rebuild(fileName: fileName) { _, destination in
            try Data(repeating: 0x00, count: 512).write(to: destination)
        }

        #expect(outcome == .failed)
        #expect(!CaptureJournalRepair.isReadable(Self.recordingURL(fileName)))
        #expect(CaptureJournal.exists(for: fileName))
    }

    // MARK: - Recovery

    private static func insertRecording(
        fileName: String,
        state: RecordingCaptureState,
        reason: CaptureRecoveryReason? = nil,
        in context: ModelContext
    ) throws -> Recording {
        let meeting = Meeting(title: "Killed")
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting,
            fileName: fileName,
            duration: 0,
            captureState: state,
            captureRecoveryReason: reason
        )
        context.insert(recording)
        try context.save()
        return recording
    }

    @Test func activationRebuildsAKilledCaptureForTheUserToConfirm() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let fileName = try Self.makeKilledCapture(seconds: 2)
        defer { AudioFileStore.delete(fileName: fileName) }
        // The state the synchronous activation sweep leaves a killed capture
        // in (`RecordingRecoveryTests` covers that transition). Not run here:
        // its orphan pass would quarantine other suites' fixtures.
        let recording = try Self.insertRecording(
            fileName: fileName,
            state: .recoveryNeeded,
            reason: .unreadableFile,
            in: context
        )

        await RecordingRecovery.repairFromCaptureJournals(modelContainer: container)

        #expect(recording.captureState == .recoveryNeeded)
        #expect(recording.captureRecoveryReason == .interruptedDuringCapture)
        #expect(recording.duration > 1.8)
        #expect(recording.fileSize > 0)
        #expect(!CaptureJournal.exists(for: fileName))

        let error = await RecordingRecovery.retryRecovery(for: recording, context: context)
        #expect(error == nil)
        #expect(recording.captureState == .ready)
    }

    @Test func explicitRetryRebuildsFromTheJournal() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let fileName = try Self.makeKilledCapture(seconds: 1)
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = try Self.insertRecording(
            fileName: fileName,
            state: .recoveryNeeded,
            reason: .unreadableFile,
            in: context
        )

        let error = await RecordingRecovery.retryRecovery(for: recording, context: context)

        #expect(error == nil)
        #expect(recording.captureState == .ready)
        #expect(recording.captureRecoveryReason == nil)
        #expect(recording.duration > 0.8)
        #expect(!CaptureJournal.exists(for: fileName))
    }

    @Test func explicitRetryStillFailsWithoutAJournal() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.undecodableM4A(at: Self.recordingURL(fileName))
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = try Self.insertRecording(
            fileName: fileName,
            state: .recoveryNeeded,
            reason: .unreadableFile,
            in: context
        )

        let error = await RecordingRecovery.retryRecovery(for: recording, context: context)

        #expect(error != nil)
        #expect(recording.captureState == .recoveryNeeded)
    }

    @Test func aCaptureStillRunningIsNeverRebuilt() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let fileName = try Self.makeKilledCapture()
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = try Self.insertRecording(fileName: fileName, state: .recording, in: context)

        await RecordingRecovery.repairFromCaptureJournals(modelContainer: container) { _, _ in
            Issue.record("the file a live capture is writing must not be rebuilt")
        }

        #expect(recording.captureState == .recording)
        #expect(CaptureJournal.exists(for: fileName))
    }

    @Test func aFailedRebuildLeavesTheRowAsItWas() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let fileName = try Self.makeKilledCapture()
        defer { AudioFileStore.delete(fileName: fileName) }
        let recording = try Self.insertRecording(
            fileName: fileName,
            state: .recoveryNeeded,
            reason: .unreadableFile,
            in: context
        )

        await RecordingRecovery.repairFromCaptureJournals(modelContainer: container) { _, _ in throw ExportFailed() }

        #expect(recording.captureRecoveryReason == .unreadableFile)
        #expect(CaptureJournal.exists(for: fileName))
    }
}
