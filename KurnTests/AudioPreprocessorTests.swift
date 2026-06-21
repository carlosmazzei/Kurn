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
        let inputURL = try Self.makeToneFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let preprocessor = AudioPreprocessor()
        let outURL = try await preprocessor.process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outFile = try AVAudioFile(forReading: outURL)
        #expect(outFile.fileFormat.sampleRate == 16_000)
        #expect(outFile.fileFormat.channelCount == 1)
        #expect(outFile.length > 0)
    }

    @Test func cleanupOnlyRemovesFilesInsideTemporaryDirectory() async throws {
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

    /// Write a short 440 Hz tone to a mono AAC .m4a for use as input.
    private static func makeToneFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
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
