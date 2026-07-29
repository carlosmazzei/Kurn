//
//  PlaybackEnhancementTests.swift
//  KurnTests
//
//  The renderer's output, and the file lifecycle around it.
//
//  The lifecycle half matters more than it looks. A derived second copy of every
//  recording touches the orphan sweep, the storage totals and every delete path,
//  and getting any of them wrong is silent — the user sees a duplicate row, or a
//  file that never goes away.
//

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Kurn

struct PlaybackEnhancementTests {

    // MARK: - Renderer

    @Test func rendersAMonoPlayableCopy() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.2)
            defer { AudioFileStore.delete(fileName: fileName) }

            let size = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            #expect(size > 0)

            let url = AudioFileStore.enhancedURL(fileName: fileName)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length > 0)
        }
    }

    /// The enhanced copy must never be louder than full scale — the chain applies
    /// a normalization gain and a makeup gain, and the limiter is the only thing
    /// between them and clipping.
    @Test func doesNotClipALoudRecording() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.9)
            defer { AudioFileStore.delete(fileName: fileName) }

            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            let samples = try await Self.decode(AudioFileStore.enhancedURL(fileName: fileName))
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            #expect(peak < 1.02)
        }
    }

    /// A quiet recording is what the feature exists for: it must come out louder.
    @Test func liftsAQuietRecording() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.02)
            defer { AudioFileStore.delete(fileName: fileName) }

            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            let original = try await Self.decode(AudioFileStore.resolveURL(fileName: fileName))
            let enhanced = try await Self.decode(AudioFileStore.enhancedURL(fileName: fileName))
            #expect(Self.rms(enhanced) > Self.rms(original) * 2)
        }
    }

    @Test func failedRenderLeavesNoTempFile() async throws {
        try await tempFileTestLock.run {
            let fileName = "kurn-test-\(UUID().uuidString).m4a"
            let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
            try Data([0x00, 0x01, 0x02]).write(to: url)
            defer { AudioFileStore.delete(fileName: fileName) }

            let before = Self.recentTempFiles(prefix: "kurn_enh_")
            await #expect(throws: Error.self) {
                _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            }
            #expect(Self.recentTempFiles(prefix: "kurn_enh_").subtracting(before).isEmpty)
        }
    }

    // MARK: - Lifecycle

    /// The reason enhanced copies live in a subdirectory rather than beside the
    /// originals with a suffix: every existing sweep over the recordings directory
    /// is shallow, so a nested copy is invisible to all of them at once. A
    /// suffixed one would be adopted by the orphan sweep as a second `Recording`
    /// and shown in the library as a duplicate.
    @Test func enhancedCopyLivesOutsideTheRecordingsScan() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.2)
            defer { AudioFileStore.delete(fileName: fileName) }
            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)

            let names = (try? FileManager.default.contentsOfDirectory(
                at: AudioFileStore.recordingsDirectoryURL,
                includingPropertiesForKeys: nil
            ))?.map(\.lastPathComponent) ?? []
            // Exactly one `.m4a` for this recording is visible to a shallow scan.
            #expect(names.filter { $0 == fileName }.count == 1)
            #expect(AudioFileStore.enhancedAudioBytes() > 0)
        }
    }

    /// Deleting a recording has to take its derived copy with it, and does so
    /// without any caller knowing the copy exists — the enhanced directory is in
    /// `AudioFileStore.delete`'s search list.
    @Test func deletingTheRecordingRemovesTheEnhancedCopy() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.2)
            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            #expect(AudioFileStore.hasEnhancedAudio(fileName: fileName))

            AudioFileStore.delete(fileName: fileName)
            #expect(!AudioFileStore.hasEnhancedAudio(fileName: fileName))
            #expect(!FileManager.default.fileExists(
                atPath: AudioFileStore.resolveURL(fileName: fileName).path
            ))
        }
    }

    @Test func deletingOnlyTheEnhancedCopyKeepsTheRecording() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.2)
            defer { AudioFileStore.delete(fileName: fileName) }
            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)

            AudioFileStore.deleteEnhancedAudio(fileName: fileName)
            #expect(!AudioFileStore.hasEnhancedAudio(fileName: fileName))
            #expect(FileManager.default.fileExists(
                atPath: AudioFileStore.resolveURL(fileName: fileName).path
            ))
        }
    }

    // MARK: - Staleness

    @MainActor
    @Test func staleOrMissingCopiesAreNotUsed() throws {
        let container = TestModelContainer.make()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Test")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "missing.m4a", duration: 10)
        context.insert(recording)

        let current = PlaybackEnhancementRenderer.currentVersion

        // Never rendered.
        #expect(!recording.hasEnhancedAudio(currentVersion: current))

        // Stamped, but the file is gone — "Delete all data" and the storage screen
        // can remove it without touching the row.
        recording.enhancedAudioVersion = current
        #expect(!recording.hasEnhancedAudio(currentVersion: current))

        // Stamped by an older tuning.
        recording.enhancedAudioVersion = current - 1
        #expect(!recording.hasEnhancedAudio(currentVersion: current))

        recording.enhancedFileSize = 123
        recording.clearEnhancedAudio()
        #expect(recording.enhancedAudioVersion == 0)
        #expect(recording.enhancedFileSize == 0)
    }

    // MARK: - Helpers

    private static func seedRecordingFile(amplitude: Float) throws -> String {
        let fileName = "kurn-test-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 2.0, amplitude: amplitude, at: url)
        return fileName
    }

    /// Decode through the app's own offline render path: `AVAudioFile.read` and
    /// `AVAudioConverter` both fail on these AAC files on device.
    private static func decode(_ url: URL) async throws -> [Float] {
        guard let format = OfflineAudioRenderer.monoFormat(sampleRate: 24_000) else {
            throw AppError.audioError("Could not build decode format")
        }
        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: AppError.audioError("Could not decode test audio"),
            logLabel: "test.decode"
        )
        var samples: [Float] = []
        try await renderer.render(url: url) { buffer in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            samples.append(
                contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
            )
        }
        return samples
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    private static func recentTempFiles(prefix: String) -> Set<URL> {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        return Set(files.filter { $0.lastPathComponent.hasPrefix(prefix) })
    }
}
