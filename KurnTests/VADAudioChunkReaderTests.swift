import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct VADAudioChunkReaderTests {
    private struct ConsumerFailure: Error {}

    @Test(arguments: [257, 4096, 8192, 20000])
    func chunkBoundariesAndThePartialTailPreserveEverySample(chunkSize: Int) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1.03125)])
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
            var chunks: [[Float]] = []
            var progress: [Double] = []
            try VADAudioChunkReader.read(
                url: url, sampleRate: 16_000, chunkSize: chunkSize,
                onProgress: { progress.append($0) }, onChunk: { chunks.append($0) }
            )
            #expect(expected.count == 16_500)
            #expect(chunks.flatMap { $0 } == expected)
            #expect(chunks.dropLast().allSatisfy { $0.count == chunkSize })
            #expect(chunks.last?.count == expected.count % chunkSize)
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= chunkSize })
            #expect(progress.last == 1)
            #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(progress.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func anExactChunkBoundaryDoesNotEmitAnEmptyTail() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1)])
            defer { try? FileManager.default.removeItem(at: url) }
            var sizes: [Int] = []
            var progress: [Double] = []
            try VADAudioChunkReader.read(
                url: url, sampleRate: 16_000, chunkSize: 4000,
                onProgress: { progress.append($0) }, onChunk: { sizes.append($0.count) }
            )
            #expect(sizes == [4000, 4000, 4000, 4000])
            #expect(progress == [0.25, 0.5, 0.75, 1])
        }
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func resamplingMatchesTheContinuousWholeFileRender(sampleRate: Double) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(330, 0.5), (770, 0.25)], sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
            var actual: [Float] = []
            try VADAudioChunkReader.read(url: url, sampleRate: 16_000, chunkSize: 997) {
                actual.append(contentsOf: $0)
            }
            #expect(expected.count == 12_000)
            #expect(actual == expected)
        }
    }

    @Test func compressedAACUsesTheSameDecodePath() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(seconds: 0.5)
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
            var actual: [Float] = []
            try VADAudioChunkReader.read(url: url, sampleRate: 16_000, chunkSize: 3000) {
                actual.append(contentsOf: $0)
            }
            #expect(!expected.isEmpty)
            #expect(actual == expected)
        }
    }

    @Test func stereoDownmixMatchesTheWholeFileLoader() async throws {
        try await tempFileTestLock.run {
            let url = AudioFixtures.tempURL(ext: "wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try autoreleasepool {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
                buffer.frameLength = 12_000
                let channels = try #require(buffer.floatChannelData)
                for index in 0..<12_000 {
                    channels[0][index] = Float(sin(Double(index) * 0.1)) * 0.25
                    channels[1][index] = Float(sin(Double(index) * 0.2)) * 0.5
                }
                try file.write(from: buffer)
            }
            let expected = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
            var actual: [Float] = []
            try VADAudioChunkReader.read(url: url, sampleRate: 16_000, chunkSize: 700) {
                actual.append(contentsOf: $0)
            }
            #expect(expected.count == 4000)
            #expect(actual == expected)
        }
    }

    @Test func anEmptyFileHasNoChunksAndCompletesProgress() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [])
            defer { try? FileManager.default.removeItem(at: url) }
            var progress: [Double] = []
            try VADAudioChunkReader.read(
                url: url, sampleRate: 16_000, chunkSize: 4096, onProgress: { progress.append($0) }
            ) { _ in Issue.record("an empty file must not emit a chunk") }
            #expect(progress == [1])
        }
    }

    @Test(arguments: [1000, 20000])
    func cancellationDuringConsumptionStopsBeforeTheNextChunk(chunkSize: Int) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1)])
            defer { try? FileManager.default.removeItem(at: url) }
            let work = Task.detached {
                var count = 0
                do {
                    try VADAudioChunkReader.read(url: url, sampleRate: 16_000, chunkSize: chunkSize) { _ in
                        count += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    Issue.record("cancelled decoding must throw")
                } catch {
                    #expect(error is CancellationError)
                }
                return count
            }
            #expect(await work.value == 1)
        }
    }

    @Test func cancellationBeforeOpeningTheFileIsHonored() async {
        let work = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try VADAudioChunkReader.read(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: 16_000, chunkSize: 1000) { _ in
                    Issue.record("cancelled decoding must not emit a chunk")
                }
            }
        }
        await work.value
    }

    @Test func consumerErrorsStopRenderingAndPropagate() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1)])
            defer { try? FileManager.default.removeItem(at: url) }
            var calls = 0
            #expect(throws: ConsumerFailure.self) {
                try VADAudioChunkReader.read(url: url, sampleRate: 16_000, chunkSize: 1000) { _ in
                    calls += 1
                    throw ConsumerFailure()
                }
            }
            #expect(calls == 1)
        }
    }

    @Test(arguments: [0, -1])
    func invalidChunkSizesAreRejected(chunkSize: Int) {
        #expect(throws: (any Error).self) {
            try VADAudioChunkReader.read(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: 16_000, chunkSize: chunkSize) { _ in }
        }
    }

    @Test func unreadableInputIsNotReportedAsSuccessful() {
        var progress: [Double] = []
        #expect(throws: (any Error).self) {
            try VADAudioChunkReader.read(
                url: URL(fileURLWithPath: "/missing.wav"), sampleRate: 16_000, chunkSize: 4096,
                onProgress: { progress.append($0) }
            ) { _ in Issue.record("unreadable input must not emit a chunk") }
        }
        #expect(progress.isEmpty)
    }

    @Test(arguments: [0.0, -16_000.0, Double.infinity, Double.nan])
    func invalidSampleRatesAreRejected(sampleRate: Double) {
        #expect(throws: (any Error).self) {
            try VADAudioChunkReader.read(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: sampleRate, chunkSize: 4096) { _ in }
        }
    }
}
