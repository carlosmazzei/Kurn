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
