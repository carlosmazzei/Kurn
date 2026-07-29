//
//  AudioPreprocessorTests.swift
//  KurnTests
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct AudioPreprocessorTests {

    @Test func processProducesMono16kHzFile() async throws {
        try await tempFileTestLock.run {
            let inputURL = try AudioFixtures.m4aTone(seconds: 1.0)
            defer { try? FileManager.default.removeItem(at: inputURL) }

            let preprocessor = AudioPreprocessor()
            let outURL = try await preprocessor.process(url: inputURL)
            defer { try? FileManager.default.removeItem(at: outURL) }

            let outFile = try AVAudioFile(forReading: outURL)
            #expect(outFile.fileFormat.sampleRate == 16_000)
            #expect(outFile.fileFormat.channelCount == 1)
            #expect(outFile.length > 0)
        }
    }

    @Test func cleanupOnlyRemovesFilesInsideTemporaryDirectory() async throws {
        try await tempFileTestLock.run {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a")
            try Data([0x01]).write(to: tmpURL)

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(UUID().uuidString).m4a")
            try Data([0x02]).write(to: documentsURL)
            defer { try? FileManager.default.removeItem(at: documentsURL) }

            let preprocessor = AudioPreprocessor()
            await preprocessor.cleanup(tmpURL)
            await preprocessor.cleanup(documentsURL)

            #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
            #expect(FileManager.default.fileExists(atPath: documentsURL.path))
        }
    }

    @Test func processFailureDoesNotLeakCleanedTempFile() async throws {
        try await tempFileTestLock.run {
            let tmp = FileManager.default.temporaryDirectory
            let invalidURL = tmp.appendingPathComponent("\(UUID().uuidString).m4a")
            try Data([0x00, 0x01, 0x02]).write(to: invalidURL)
            defer { try? FileManager.default.removeItem(at: invalidURL) }

            let prefix = "kurn_clean_"
            let before = recentTempFiles(prefix: prefix, seconds: 5)

            let preprocessor = AudioPreprocessor()
            await #expect(throws: Error.self) {
                try await preprocessor.process(url: invalidURL)
            }

            let after = recentTempFiles(prefix: prefix, seconds: 5)
            #expect(after.subtracting(before).isEmpty)
        }
    }

    /// A quiet recording should be lifted toward the target speech level.
    @Test func quietRecordingIsLifted() async throws {
        try await tempFileTestLock.run {
            let inputURL = try AudioFixtures.m4aTone(seconds: 1.5, amplitude: 0.02)
            defer { try? FileManager.default.removeItem(at: inputURL) }

            let preprocessor = AudioPreprocessor()
            let outURL = try await preprocessor.process(url: inputURL)
            defer { try? FileManager.default.removeItem(at: outURL) }

            let input = try await Self.decodedSamples(url: inputURL)
            let output = try await Self.decodedSamples(url: outURL)
            #expect(Self.rms(output) / Self.rms(input) > 2)
        }
    }

    /// The regression the two-pass chain exists to prevent. A recording that is
    /// already close to full scale used to receive a fixed +11 dB (a +8 dB makeup
    /// on top of the limiter's +3 dB pre-gain), which drove the limiter into hard
    /// clipping and flattened the waveform.
    ///
    /// Crest factor is what catches that: a clean sine has peak/RMS = sqrt(2), and
    /// a limited one collapses toward 1.0 as its tops square off. A compressor
    /// acting on a steady tone only applies a static gain, so it leaves the crest
    /// factor alone — only clipping moves it.
    @Test func loudRecordingIsNotDrivenIntoTheLimiter() async throws {
        try await tempFileTestLock.run {
            let inputURL = try AudioFixtures.m4aTone(seconds: 1.5, amplitude: 0.9)
            defer { try? FileManager.default.removeItem(at: inputURL) }

            let preprocessor = AudioPreprocessor()
            let outURL = try await preprocessor.process(url: inputURL)
            defer { try? FileManager.default.removeItem(at: outURL) }

            let output = try await Self.decodedSamples(url: outURL)
            let crest = Self.peak(output) / Self.rms(output)
            #expect(crest > 1.30)
            // Full scale, with a little slack for AAC decode overshoot.
            #expect(Self.peak(output) < 1.02)
        }
    }

    // MARK: - Helpers

    /// Decode through the app's own offline render path. `AVAudioFile.read` and
    /// `AVAudioConverter` both fail on these AAC files on device (see
    /// `OfflineAudioRenderer`'s header), so tests read them the same way
    /// production does.
    private static func decodedSamples(url: URL, sampleRate: Double = 16_000) async throws -> [Float] {
        guard let format = OfflineAudioRenderer.monoFormat(sampleRate: sampleRate) else {
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

    private static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private func recentTempFiles(prefix: String, seconds: TimeInterval) -> Set<URL> {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-seconds)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.nameKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return Set(files.filter { file in
            guard file.lastPathComponent.hasPrefix(prefix) else { return false }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return date.map { $0 >= cutoff } ?? false
        })
    }
}
