//
//  CaptureJournalTests.swift
//  KurnTests
//
//  The crash-safe capture copy: what the sink writes to it, what happens when
//  either file fails, where it lives and who removes it. The rebuild from it
//  is `CaptureJournalRepairTests`.
//
//  `@MainActor` like `RecordingRecoveryTests`, whose orphan sweep would
//  otherwise run concurrently and quarantine the fixtures written here.
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

// Nested so `RecordingsDirectorySuite`'s `.serialized` covers it.
extension RecordingsDirectorySuite {
@MainActor
struct CaptureJournalTests {

    private struct WriteFailed: Error {}

    private final class RecordingWriter: AudioFileWriting {
        var writes = 0
        var failing = false
        func write(from buffer: AVAudioPCMBuffer) throws {
            if failing { throw WriteFailed() }
            writes += 1
        }
    }

    private static func buffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        return buffer
    }

    // MARK: - Naming

    @Test func journalNamesMirrorTheRecording() {
        let fileName = "\(UUID().uuidString)_\(UUID().uuidString).m4a"
        let journal = CaptureJournal.journalFileName(for: fileName)
        #expect(journal.hasSuffix(".aac"))
        #expect(CaptureJournal.recordingFileName(forJournal: journal) == fileName)
        #expect(CaptureJournal.url(for: fileName).deletingLastPathComponent() == CaptureJournal.directoryURL)
        #expect(CaptureJournal.directoryURL.deletingLastPathComponent().standardizedFileURL
            == AudioFileStore.recordingsDirectoryURL.standardizedFileURL)
    }

    @Test func journalSettingsAreTheRecordingsAsADTS() {
        let settings = CaptureJournal.settings(bitRate: 48_000)
        #expect(settings[AVAudioFileTypeKey] as? Int == Int(kAudioFileAAC_ADTSType))
        #expect(settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        #expect(settings[AVSampleRateKey] as? Double == AudioRecorderService.storageSampleRate)
        #expect(settings[AVEncoderBitRateKey] as? Int == 48_000)
    }

    // MARK: - JournaledCaptureFile

    @Test func everyBufferReachesBothFiles() throws {
        let primary = RecordingWriter()
        let journal = RecordingWriter()
        let file = JournaledCaptureFile(primary: primary, journal: journal)

        try file.write(from: Self.buffer())
        try file.write(from: Self.buffer())

        #expect(primary.writes == 2)
        #expect(journal.writes == 2)
        #expect(file.hasJournal)
    }

    @Test func aJournalFailureDetachesItAndKeepsRecording() throws {
        let primary = RecordingWriter()
        let journal = RecordingWriter()
        var reported = 0
        let file = JournaledCaptureFile(primary: primary, journal: journal) { reported += 1 }

        journal.failing = true
        try file.write(from: Self.buffer())
        journal.failing = false
        try file.write(from: Self.buffer())

        #expect(primary.writes == 2)
        #expect(journal.writes == 0)
        #expect(!file.hasJournal)
        #expect(reported == 1)
    }

    @Test func aRecordingFailureIsThrownAfterTheJournalKeptTheBuffer() throws {
        let primary = RecordingWriter()
        let journal = RecordingWriter()
        let file = JournaledCaptureFile(primary: primary, journal: journal)
        primary.failing = true

        #expect(throws: WriteFailed.self) { try file.write(from: Self.buffer()) }
        #expect(journal.writes == 1)
    }

    // MARK: - Opening

    @Test func openJournaledWritesTheJournalBesideTheRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AudioFixtures.tempURL(ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try autoreleasepool {
            let file = try CaptureOutputFile.openJournaled(at: url, bitRate: 48_000, journalDirectory: { directory })
            let journaled = try #require(file as? JournaledCaptureFile)
            #expect(journaled.hasJournal)
        }

        let journalURL = directory.appendingPathComponent(CaptureJournal.journalFileName(for: url.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test func aJournalThatCannotOpenLeavesThePlainRecording() throws {
        let url = AudioFixtures.tempURL(ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        struct NoDirectory: Error {}

        let file = try CaptureOutputFile.openJournaled(at: url, bitRate: 48_000, journalDirectory: { throw NoDirectory() })

        #expect(file is AVAudioFile)
    }

    @Test func aRejectedJournalBitRateIsRetriedWithoutOne() throws {
        let directory = FileManager.default.temporaryDirectory
        var journalBitRates: [Int?] = []
        let file = try CaptureOutputFile.openJournaled(
            at: AudioFixtures.tempURL(ext: "m4a"),
            bitRate: 48_000,
            make: { url, settings in
                if url.pathExtension == CaptureJournal.fileExtension {
                    journalBitRates.append(settings[AVEncoderBitRateKey] as? Int)
                    if settings[AVEncoderBitRateKey] != nil { throw WriteFailed() }
                }
                return RecordingWriter()
            },
            journalDirectory: { directory }
        )
        #expect(file is JournaledCaptureFile)
        #expect(journalBitRates == [48_000, nil])
    }

    // MARK: - Lifetime

    @Test func deletingARecordingDeletesItsJournal() throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.adtsTone(seconds: 0.2, at: CaptureJournal.url(for: fileName))
        #expect(CaptureJournal.exists(for: fileName))

        AudioFileStore.delete(fileName: fileName)

        #expect(!CaptureJournal.exists(for: fileName))
    }

    @Test func finalizingAReadableRecordingDiscardsItsJournal() throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.m4aTone(seconds: 1, at: AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName))
        try AudioFixtures.adtsTone(seconds: 1, at: CaptureJournal.url(for: fileName))
        defer { AudioFileStore.delete(fileName: fileName) }

        _ = try RecordingFileFinalizer(protect: { _ in }).finalize(fileName: fileName)

        #expect(!CaptureJournal.exists(for: fileName))
    }

    @Test func aFailedFinalizationKeepsTheJournal() throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.undecodableM4A(at: AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName))
        try AudioFixtures.adtsTone(seconds: 1, at: CaptureJournal.url(for: fileName))
        defer { AudioFileStore.delete(fileName: fileName) }

        #expect(throws: RecordingFileFinalizationError.unreadable) {
            _ = try RecordingFileFinalizer(protect: { _ in }).finalize(fileName: fileName)
        }
        #expect(CaptureJournal.exists(for: fileName))
    }

    @Test func journalsAreListedByTheirRecording() throws {
        let fileName = AudioFileStore.fileName(meetingID: UUID(), recordingID: UUID())
        try AudioFixtures.adtsTone(seconds: 0.2, at: CaptureJournal.url(for: fileName))
        defer { AudioFileStore.delete(fileName: fileName) }

        #expect(CaptureJournal.recordingFileNamesWithJournal().contains(fileName))
    }
}
}
