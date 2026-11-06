import Foundation
import KurnCore

enum VADAudioChunkReader {
    /// One continuous render preserves the resampler state across chunk boundaries.
    static func read(
        url: URL,
        sampleRate: Double,
        chunkSize: Int,
        onProgress: ((Double) -> Void)? = nil,
        onChunk: ([Float]) throws -> Void
    ) throws {
        try Task.checkCancellation()
        guard chunkSize > 0, sampleRate.isFinite, sampleRate > 0 else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }
        var chunk: [Float] = []
        chunk.reserveCapacity(chunkSize)
        var delivered = 0
        var lastProgress = 0.0
        try VADAudioLoader.renderMono(url: url, sampleRate: sampleRate) { samples, expectedFrames in
            try Task.checkCancellation()
            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = offset + min(chunkSize - chunk.count, samples.count - offset)
                chunk.append(contentsOf: samples[offset..<end])
                offset = end
                if chunk.count == chunkSize {
                    try onChunk(chunk)
                    try Task.checkCancellation()
                    delivered += chunk.count
                    chunk.removeAll(keepingCapacity: true)
                    lastProgress = min(1, Double(delivered) / Double(max(1, expectedFrames)))
                    onProgress?(lastProgress)
                }
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty { try onChunk(chunk) }
        try Task.checkCancellation()
        if lastProgress < 1 { onProgress?(1) }
    }
}
