import Foundation
import Testing
@testable import Kurn

struct SpeakerDiarizerFrameTests {
    @Test(arguments: [0, 533, 534, 1600, 2133, 2134, 4807])
    func frameBoundariesAndTrailingThresholdMatchWholeArray(sampleCount: Int) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: sampleCount == 0 ? [] : [(150, Double(sampleCount) / 16_000)])
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    @Test(arguments: [16_000.0, 44_100.0, 48_000.0])
    func everyFeatureMatchesWholeArrayAfterResampling(sampleRate: Double) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(150, 0.4), (0, 0.6), (270, 0.43)], sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    @Test func compressedAudioMatchesWholeArray() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(seconds: 0.7)
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    private func compareWithWholeArray(url: URL) async throws {
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
        let diarizer = SpeakerDiarizer()
        var expected: [SpeakerDiarizer.Frame] = []
        var offset = 0
        while offset + 1600 <= samples.count {
            expected.append(await diarizer.makeFrame(
                Array(samples[offset..<offset + 1600]), time: Double(offset) / 16_000, sampleRate: 16_000
            ))
            offset += 1600
        }
        if samples.count - offset > 1600 / 3 {
            expected.append(await diarizer.makeFrame(
                Array(samples[offset...]), time: Double(offset) / 16_000, sampleRate: 16_000
            ))
        }
        let actual = try await diarizer.readFrames(url: url)
        #expect(actual == expected)
    }
}
