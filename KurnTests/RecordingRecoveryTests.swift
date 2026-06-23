//
//  RecordingRecoveryTests.swift
//  KurnTests
//

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingRecoveryTests {

    @Test func reattachesOrphanedFileToItsMeeting() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        try context.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.fileName == fileName)
        #expect(recordings.first?.meeting?.id == meeting.id)
        #expect((recordings.first?.duration ?? 0) > 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func deletesOrphanedFileWithNoMatchingMeeting() throws {
        let container = TestModelContainer.make()

        let fileName = AudioFileStore.fileName(meetingID: UUID())
        _ = try Self.makeToneFile(named: fileName, seconds: 1.0)

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: AudioFileStore.documentsURL.appendingPathComponent(fileName).path))
    }

    @Test func leavesAlreadyKnownFilesUntouched() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try Self.makeToneFile(named: fileName, seconds: 1.0)
        defer { AudioFileStore.delete(fileName: fileName) }

        let existing = Recording(meeting: meeting, fileName: fileName, duration: 1.0)
        context.insert(existing)
        try context.save()

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Write a short 440 Hz tone directly into the real Documents directory
    /// under `named`, mirroring how `AudioRecorderService` writes recordings.
    private static func makeToneFile(named fileName: String, seconds: Double) throws -> URL {
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData else {
            throw AppError.audioError("Could not build tone buffer")
        }
        buffer.frameLength = frameCount
        let omega = 2.0 * Double.pi * 440.0
        for i in 0..<Int(frameCount) {
            data[0][i] = Float(sin(omega * Double(i) / sampleRate)) * 0.5
        }
        try file.write(from: buffer)
        return url
    }
}
