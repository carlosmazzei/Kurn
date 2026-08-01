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
            let fileName = try Self.seedRenderSource(amplitude: 0.2)
            defer { AudioFileStore.delete(fileName: fileName) }
            let progress = EnhancementProgressSnapshots()

            let size = try await PlaybackEnhancementRenderer().render(fileName: fileName) {
                progress.append($0)
            }
            #expect(size > 0)
            #expect(progress.values.count > 5)
            #expect(progress.values.first == 0)
            #expect(progress.values.last == 1)
            #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })

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
            let fileName = try Self.seedRenderSource(amplitude: 0.9)
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
            let fileName = try Self.seedRenderSource(amplitude: 0.02)
            defer { AudioFileStore.delete(fileName: fileName) }

            _ = try await PlaybackEnhancementRenderer().render(fileName: fileName)
            let original = try await Self.decode(AudioFileStore.resolveURL(fileName: fileName))
            let enhanced = try await Self.decode(AudioFileStore.enhancedURL(fileName: fileName))
            #expect(Self.rms(enhanced) > Self.rms(original) * 2)
        }
    }

    @Test func failedRenderLeavesNoTempFile() async throws {
        try await tempFileTestLock.run {
            let fileName = "kurn-test-\(UUID().uuidString).caf"
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
            try Self.seedEnhancedFile(fileName: fileName)

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
            try Self.seedEnhancedFile(fileName: fileName)
            #expect(AudioFileStore.hasEnhancedAudio(fileName: fileName))

            AudioFileStore.delete(fileName: fileName)
            #expect(!AudioFileStore.hasEnhancedAudio(fileName: fileName))
            #expect(!FileManager.default.fileExists(
                atPath: AudioFileStore.resolveURL(fileName: fileName).path
            ))
        }
    }

    @Test func deletingAllEnhancedCopiesClearsFilesAndRows() async throws {
        try await tempFileTestLock.run {
            let fileName = try Self.seedRecordingFile(amplitude: 0.2)
            defer { AudioFileStore.delete(fileName: fileName) }
            try Self.seedEnhancedFile(fileName: fileName)

            await MainActor.run {
                let container = TestModelContainer.make()
                let context = ModelContext(container)
                let meeting = Meeting(title: "Test")
                context.insert(meeting)
                let recording = Recording(meeting: meeting, fileName: fileName, duration: 10)
                recording.enhancedAudioVersion = PlaybackEnhancementRenderer.currentVersion
                recording.enhancedFileSize = 2
                context.insert(recording)
                try context.save()

                let viewModel = PlaybackEnhancementViewModel(modelContext: context)
                viewModel.deleteAllEnhancedAudio()

                #expect(!AudioFileStore.hasEnhancedAudio(fileName: fileName))
                #expect(recording.enhancedAudioVersion == 0)
                #expect(recording.enhancedFileSize == 0)
            }
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

    /// A detail screen can be destroyed and rebuilt while the app-wide
    /// coordinator is still rendering. A repeated request must observe the
    /// existing task and must not claim the copy is ready before it lands.
    @MainActor
    @Test func inFlightEnhancementRemainsBusyAcrossRepeatedRequests() async {
        let context = ModelContext(TestModelContainer.make())
        let recording = Recording(fileName: "in-flight.m4a", duration: 10)
        context.insert(recording)
        let viewModel = PlaybackEnhancementViewModel(
            modelContext: context,
            renderer: SuspendedEnhancementRenderer()
        )

        viewModel.ensureEnhancedAudio(for: recording)
        #expect(viewModel.isEnhancing(recording))
        #expect(viewModel.progress(for: recording) == 0)

        var reportedReady = false
        viewModel.ensureEnhancedAudio(for: recording) {
            reportedReady = true
        }
        #expect(!reportedReady)

        viewModel.cancel(recording)
        for _ in 0..<20 where viewModel.isEnhancing(recording) {
            await Task.yield()
        }
        #expect(!viewModel.isEnhancing(recording))
        #expect(viewModel.progress(for: recording) == nil)
    }

    // MARK: - Helpers

    /// Put a file where an enhanced copy would live, without running the
    /// renderer. The lifecycle tests are about which directory a file sits in and
    /// what removes it — rendering real audio for them would couple them to the
    /// DSP and cost two offline render passes each.
    private static func seedEnhancedFile(fileName: String) throws {
        AudioFileStore.ensureEnhancedDirectory()
        try Data([0x00, 0x01]).write(to: AudioFileStore.enhancedURL(fileName: fileName))
    }

    private static func seedRecordingFile(amplitude: Float) throws -> String {
        let fileName = "kurn-test-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.2, amplitude: amplitude, at: url)
        return fileName
    }

    /// Recovery tests deliberately sweep orphaned `.m4a` files. Renderer tests
    /// take longer now that they include inference, so use an AAC-in-CAF fixture
    /// that cannot be mistaken for an abandoned recording by a concurrent sweep.
    private static func seedRenderSource(amplitude: Float) throws -> String {
        let fileName = "kurn-test-\(UUID().uuidString).caf"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.2, amplitude: amplitude, at: url)
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

private struct SuspendedEnhancementRenderer: PlaybackEnhancementRendering {
    func render(
        fileName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Int64 {
        onProgress?(0.25)
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return 1
    }
}

private final class EnhancementProgressSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Double] = []

    func append(_ progress: Double) {
        lock.withLock { snapshots.append(progress) }
    }

    var values: [Double] {
        lock.withLock { snapshots }
    }
}
