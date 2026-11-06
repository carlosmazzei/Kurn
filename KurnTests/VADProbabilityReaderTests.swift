import Foundation
import Testing
@testable import Kurn

#if canImport(FluidAudio)
import FluidAudio
#endif

struct VADProbabilityReaderTests {
    private struct ConsumerFailure: Error {}

    #if canImport(FluidAudio)
    @Test func bufferSizeMatchesThePinnedSDKModelWindow() {
        #expect(VadManager.chunkSize == VADAudioBufferReader.bufferSize)
    }
    #endif

    @Test(arguments: [16_000.0, 44_100.0, 48_000.0])
    func streamingMatchesWholeArrayChunking(sampleRate: Double) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(150, 0.256), (0, 0.13), (270, 0.4)], sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    @Test func compressedInputPreservesSamplesAndStateOrder() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(seconds: 0.7)
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    @Test(arguments: [0, 4096, 8192, 8193])
    func emptyExactAndPartialTailsMatchWholeArray(sampleCount: Int) async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: sampleCount == 0 ? [] : [(150, Double(sampleCount) / 16_000)])
            defer { try? FileManager.default.removeItem(at: url) }
            try await compareWithWholeArray(url: url)
        }
    }

    private func compareWithWholeArray(url: URL) async throws {
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: 16_000)
        var expected: [Float] = []
        var state: Float = 0
        for offset in stride(from: 0, to: samples.count, by: 4096) {
            state = samples[offset..<min(offset + 4096, samples.count)].reduce(state) { $0 + $1 * $1 }
            expected.append(state)
        }
        var offset = 0
        state = 0
        let result = try await VADProbabilityReader.read(url: url, sampleRate: 16_000) { chunk in
            #expect(chunk == Array(samples[offset..<min(offset + 4096, samples.count)]))
            #expect(!chunk.isEmpty && chunk.count <= 4096)
            await Task.yield()
            offset += chunk.count
            state = chunk.reduce(state) { $0 + $1 * $1 }
            return state
        }
        #expect(result.probabilities == expected)
        #expect(result.sampleCount == samples.count)
        #expect(offset == samples.count)
    }

    @Test func consumerErrorsPropagateWithoutProcessingTheRest() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(150, 1)])
            defer { try? FileManager.default.removeItem(at: url) }
            var calls = 0
            do {
                _ = try await VADProbabilityReader.read(url: url, sampleRate: 16_000) { _ in
                    calls += 1
                    throw ConsumerFailure()
                }
                Issue.record("consumer failure must propagate")
            } catch {
                #expect(error is ConsumerFailure)
            }
            #expect(calls == 1)
        }
    }

    @Test func cancellationAfterInferenceStopsBeforeTheNextChunk() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(150, 1)])
            defer { try? FileManager.default.removeItem(at: url) }
            let work = Task.detached {
                var calls = 0
                do {
                    _ = try await VADProbabilityReader.read(url: url, sampleRate: 16_000) { _ in
                        calls += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        return 0
                    }
                    Issue.record("cancellation must propagate")
                } catch {
                    #expect(error is CancellationError)
                }
                return calls
            }
            #expect(await work.value == 1)
        }
    }

    @Test func cancellationBeforeOpeningWinsOverFileErrors() async {
        let work = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await VADProbabilityReader.read(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: 16_000) { _ in
                    Issue.record("cancelled decoding must not call inference")
                    return 0
                }
                Issue.record("cancellation must propagate")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await work.value
    }

    @Test func unreadableInputThrows() async {
        do {
            _ = try await VADProbabilityReader.read(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: 16_000) { _ in
                Issue.record("unreadable input must not call inference")
                return 0
            }
            Issue.record("unreadable input must throw")
        } catch {
            #expect(!(error is CancellationError))
        }
    }

    @Test(arguments: [0.0, -16_000.0, Double.infinity, Double.nan])
    func invalidSampleRatesAreRejected(sampleRate: Double) {
        #expect(throws: (any Error).self) {
            _ = try VADAudioBufferReader(url: URL(fileURLWithPath: "/missing.wav"), sampleRate: sampleRate)
        }
    }
}
