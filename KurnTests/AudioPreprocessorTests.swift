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
}
