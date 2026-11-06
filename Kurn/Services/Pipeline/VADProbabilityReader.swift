import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

enum VADProbabilityReader {
    #if canImport(FluidAudio)
    static func segmentationResults(probabilities: [Float]) -> [VadResult] {
        let unusedState = VadState.initial()
        return probabilities.map {
            VadResult(probability: $0, isVoiceActive: false, processingTime: 0, outputState: unusedState)
        }
    }
    #endif

    static func read(
        url: URL,
        sampleRate: Double,
        isolation: isolated (any Actor)? = #isolation,
        process: ([Float]) async throws -> Float
    ) async throws -> (probabilities: [Float], sampleCount: Int) {
        try Task.checkCancellation()
        let reader = try VADAudioBufferReader(url: url, sampleRate: sampleRate)
        var probabilities: [Float] = []
        var sampleCount = 0
        var chunk: [Float] = []
        chunk.reserveCapacity(VADAudioBufferReader.bufferSize)
        while let samples = try reader.next() {
            sampleCount += samples.count
            var offset = 0
            while offset < samples.count {
                let end = offset + min(VADAudioBufferReader.bufferSize - chunk.count, samples.count - offset)
                chunk.append(contentsOf: samples[offset..<end])
                offset = end
                if chunk.count == VADAudioBufferReader.bufferSize {
                    probabilities.append(try await process(chunk))
                    try Task.checkCancellation()
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        }
        if !chunk.isEmpty {
            probabilities.append(try await process(chunk))
            try Task.checkCancellation()
        }
        return (probabilities, sampleCount)
    }
}
