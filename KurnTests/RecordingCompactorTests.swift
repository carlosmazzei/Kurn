//
//  RecordingCompactorTests.swift
//  KurnTests
//
//  Covers the pure decision layer of recording compaction — which recordings are
//  worth re-encoding and how much that saves — plus the storage-breakdown
//  aggregation. The re-encode itself needs AVFoundation and a real audio file, so
//  it is verified on device rather than here.
//

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Kurn

struct RecordingCompactorTests {

    /// One hour at the given bit rate, in bytes.
    private static func bytes(bitRate: Int, seconds: TimeInterval) -> Int64 {
        Int64(Double(bitRate) / 8 * seconds)
    }

    // MARK: - Candidacy

    @Test func recordingWellAboveTargetIsWorthCompacting() {
        // An hour recorded by the old default: 128 kbps at the mic's native rate.
        let size = Self.bytes(bitRate: 128_000, seconds: 3600)
        #expect(RecordingCompactor.isWorthCompacting(
            duration: 3600,
            fileSize: size,
            targetBitRate: AudioQuality.standard.bitRate
        ))
    }

    @Test func recordingAlreadyAtTargetIsSkipped() {
        let target = AudioQuality.standard.bitRate
        let size = Self.bytes(bitRate: target, seconds: 600)
        #expect(!RecordingCompactor.isWorthCompacting(
            duration: 600,
            fileSize: size,
            targetBitRate: target
        ))
    }

    /// Within the margin the re-encode would cost a lossy generation for almost
    /// nothing, so it must be declined.
    @Test func recordingInsideTheExcessMarginIsSkipped() {
        let target = AudioQuality.standard.bitRate
        let justUnder = Int(Double(target) * (RecordingCompactor.minimumExcessRatio - 0.05))
        #expect(!RecordingCompactor.isWorthCompacting(
            duration: 600,
            fileSize: Self.bytes(bitRate: justUnder, seconds: 600),
            targetBitRate: target
        ))
    }

    @Test func recordingJustOverTheExcessMarginIsCompacted() {
        let target = AudioQuality.standard.bitRate
        let justOver = Int(Double(target) * (RecordingCompactor.minimumExcessRatio + 0.05))
        #expect(RecordingCompactor.isWorthCompacting(
            duration: 600,
            fileSize: Self.bytes(bitRate: justOver, seconds: 600),
            targetBitRate: target
        ))
    }

    /// A row whose size has not been backfilled yet must never be re-encoded:
    /// an unknown size can't be reasoned about.
    @Test func unknownFileSizeIsSkipped() {
        #expect(!RecordingCompactor.isWorthCompacting(
            duration: 3600,
            fileSize: 0,
            targetBitRate: AudioQuality.standard.bitRate
        ))
    }

    @Test(arguments: [0.0, -1.0])
    func nonPositiveDurationIsSkipped(duration: TimeInterval) {
        #expect(!RecordingCompactor.isWorthCompacting(
            duration: duration,
            fileSize: 10_000_000,
            targetBitRate: AudioQuality.standard.bitRate
        ))
    }

    // MARK: - Savings

    @Test func savingsAreTheDifferenceAgainstTheTargetBitRate() {
        let target = AudioQuality.standard.bitRate
        let candidate = RecordingCompactor.Candidate(
            fileName: "a.m4a",
            duration: 3600,
            fileSize: Self.bytes(bitRate: 128_000, seconds: 3600)
        )
        let expected = candidate.fileSize - Self.bytes(bitRate: target, seconds: 3600)
        #expect(RecordingCompactor.estimatedSavings(for: candidate, targetBitRate: target) == expected)
    }

    @Test func skippedCandidatesSaveNothing() {
        let target = AudioQuality.standard.bitRate
        let candidate = RecordingCompactor.Candidate(
            fileName: "a.m4a",
            duration: 600,
            fileSize: Self.bytes(bitRate: target, seconds: 600)
        )
        #expect(RecordingCompactor.estimatedSavings(for: candidate, targetBitRate: target) == 0)
    }

    // MARK: - Selection

    @Test func candidatesDropSkippablesAndSortByBiggestSavingFirst() {
        let target = AudioQuality.standard.bitRate
        let big = RecordingCompactor.Candidate(
            fileName: "big.m4a",
            duration: 3600,
            fileSize: Self.bytes(bitRate: 128_000, seconds: 3600)
        )
        let small = RecordingCompactor.Candidate(
            fileName: "small.m4a",
            duration: 300,
            fileSize: Self.bytes(bitRate: 128_000, seconds: 300)
        )
        let alreadyCompact = RecordingCompactor.Candidate(
            fileName: "compact.m4a",
            duration: 3600,
            fileSize: Self.bytes(bitRate: target, seconds: 3600)
        )
        let unknown = RecordingCompactor.Candidate(fileName: "unknown.m4a", duration: 3600, fileSize: 0)

        let compactor = RecordingCompactor(targetBitRate: target)
        let selected = compactor.candidates(from: [small, alreadyCompact, big, unknown])

        #expect(selected.map(\.fileName) == ["big.m4a", "small.m4a"])
        #expect(compactor.estimatedSavings(for: selected) > 0)
    }

    @Test func totalSavingsSumTheSelectedCandidates() {
        let target = AudioQuality.standard.bitRate
        let compactor = RecordingCompactor(targetBitRate: target)
        let candidates = (0..<3).map { index in
            RecordingCompactor.Candidate(
                fileName: "\(index).m4a",
                duration: 1800,
                fileSize: Self.bytes(bitRate: 128_000, seconds: 1800)
            )
        }
        let single = RecordingCompactor.estimatedSavings(for: candidates[0], targetBitRate: target)
        #expect(compactor.estimatedSavings(for: candidates) == single * 3)
    }

    // MARK: - Largest-meetings breakdown

    @MainActor
    @Test func largestMeetingsSumsPerMeetingAndRanksBySize() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext

        let quiet = Meeting(title: "Quiet")
        let loud = Meeting(title: "Loud")
        context.insert(quiet)
        context.insert(loud)

        // Two recordings on one meeting must add up, not compete.
        for recording in [
            Recording(meeting: loud, fileName: "l1.m4a", duration: 600, fileSize: 4_000_000),
            Recording(meeting: loud, fileName: "l2.m4a", duration: 600, fileSize: 3_000_000),
            Recording(meeting: quiet, fileName: "q1.m4a", duration: 300, fileSize: 1_000_000)
        ] {
            context.insert(recording)
        }
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let usage = RecordingCompactionViewModel.largestMeetings(from: recordings, limit: 8)

        #expect(usage.count == 2)
        #expect(usage.first?.title == "Loud")
        #expect(usage.first?.bytes == 7_000_000)
        #expect(usage.first?.duration == 1200)
        #expect(usage.last?.bytes == 1_000_000)
    }

    /// Rows with an unknown size would otherwise render as "Zero KB" entries.
    @MainActor
    @Test func largestMeetingsIgnoresRecordingsWithUnknownSize() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Not measured")
        context.insert(meeting)
        context.insert(Recording(meeting: meeting, fileName: "a.m4a", duration: 600, fileSize: 0))
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(RecordingCompactionViewModel.largestMeetings(from: recordings, limit: 8).isEmpty)
    }

    // MARK: - Re-encode round trip

    /// The end-to-end path: a real AAC file in the recordings directory is
    /// re-encoded in place, gets smaller, and is still decodable at the same
    /// length. This is the invariant the whole feature rests on — a compaction
    /// that quietly truncated audio would be unrecoverable.
    @Test func compactingShrinksTheFileAndKeepsItIntact() async throws {
        try await tempFileTestLock.run {
            let fileName = "kurn-test-\(UUID().uuidString).m4a"
            let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
            // 44.1 kHz at 64 kbps, i.e. the shape the recorder used to produce.
            _ = try AudioFixtures.m4aTone(seconds: 3.0, sampleRate: 44_100, at: url)
            defer { AudioFileStore.delete(fileName: fileName) }

            let originalSize = AudioFileStore.byteSize(fileName: fileName)
            #expect(originalSize > 0)

            let compactor = RecordingCompactor(targetBitRate: AudioQuality.low.bitRate)
            let saved = try await compactor.compact(fileName: fileName)

            #expect(saved > 0)
            let newSize = AudioFileStore.byteSize(fileName: fileName)
            #expect(newSize < originalSize)
            #expect(originalSize - newSize == saved)

            let result = try AVAudioFile(forReading: AudioFileStore.resolveURL(fileName: fileName))
            #expect(result.fileFormat.channelCount == 1)
            #expect(result.fileFormat.sampleRate == AudioRecorderService.storageSampleRate)
            let duration = Double(result.length) / result.processingFormat.sampleRate
            #expect(duration > 2.5)
            #expect(duration < 3.5)
        }
    }

    /// A recording already below the storage rate must not be resampled up —
    /// that would cost bytes rather than save them.
    @Test func compactingNeverRaisesTheSampleRate() async throws {
        try await tempFileTestLock.run {
            let fileName = "kurn-test-\(UUID().uuidString).m4a"
            let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
            // 16 kHz, as a narrowband Bluetooth route would have produced.
            _ = try AudioFixtures.m4aTone(seconds: 2.0, sampleRate: 16_000, at: url)
            defer { AudioFileStore.delete(fileName: fileName) }

            let compactor = RecordingCompactor(targetBitRate: AudioQuality.low.bitRate)
            _ = try await compactor.compact(fileName: fileName)

            let result = try AVAudioFile(forReading: AudioFileStore.resolveURL(fileName: fileName))
            #expect(result.fileFormat.sampleRate == 16_000)
        }
    }

    @Test func compactingAMissingFileIsANoOp() async throws {
        let saved = try await RecordingCompactor().compact(fileName: "missing-\(UUID().uuidString).m4a")
        #expect(saved == 0)
    }

    @MainActor
    @Test func largestMeetingsRespectsTheLimit() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        for index in 0..<5 {
            let meeting = Meeting(title: "M\(index)")
            context.insert(meeting)
            context.insert(
                Recording(
                    meeting: meeting,
                    fileName: "\(index).m4a",
                    duration: 600,
                    fileSize: Int64(index + 1) * 1_000_000
                )
            )
        }
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let usage = RecordingCompactionViewModel.largestMeetings(from: recordings, limit: 2)
        #expect(usage.map(\.title) == ["M4", "M3"])
    }
}
