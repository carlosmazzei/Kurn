//
//  VADAudioCompactor.swift
//  Kurn
//
//  Builds a "compacted" copy of a recording that contains only the VAD speech
//  regions (silence removed), plus a piecewise map from the compacted timeline
//  back to the original. Transcription runs on the compacted audio — which stops
//  engines (notably Whisper) from hallucinating text over silence and cuts ASR
//  cost — and the resulting span timestamps are remapped to the original
//  timeline so they still line up with diarization and playback.
//

// AVAudioConverter's input block is `@Sendable` in the iOS 18 SDK, which makes
// the synchronous-only `convert(to:error:withInputFrom:)` pattern below (feeding
// a single non-Sendable `AVAudioPCMBuffer` once, guarded by a captured `var`)
// trip Sendable/data-race warnings even though the block never escapes. The
// block runs synchronously inside `convert`, so this is safe; `@preconcurrency`
// downgrades the false-positive concurrency diagnostics from AVFAudio.
@preconcurrency import AVFoundation
import Foundation

/// One contiguous speech run in the compacted file and where it came from.
struct TimelineSegment: Sendable, Equatable {
    var compactedStart: TimeInterval
    var originalStart: TimeInterval
    var duration: TimeInterval
}

struct CompactionResult: Sendable {
    var url: URL
    var map: [TimelineSegment]
}

/// Loads audio as mono Float samples at a target sample rate. Shared by the
/// compactor and `FluidAudioVAD`.
enum VADAudioLoader {
    static func monoSamples(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0 else { return [] }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 16_384)
        else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }

        var output: [Float] = []
        while true {
            try file.read(into: inBuf)
            let isEOF = inBuf.frameLength == 0
            let ratio = sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(max(1, inBuf.frameLength)) * ratio) + 1_024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }

            // The converter's input block is `@Sendable`, but it runs
            // synchronously inside `convert` on this thread, so this one-shot
            // "feed the buffer once" flag is not actually shared across threads.
            nonisolated(unsafe) var provided = false
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                if isEOF { inputStatus.pointee = .endOfStream; return nil }
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw AppError.audioError(convError.localizedDescription) }
            if let channel = outBuf.floatChannelData, outBuf.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outBuf.frameLength)))
            }
            if isEOF || status == .endOfStream { break }
        }
        return output
    }
}

struct VADAudioCompactor {

    private let sampleRate: Double = 16_000

    /// Build the compacted file + timeline map, or `nil` when compaction isn't
    /// worthwhile (no regions, regions ~cover the clip, or trim saves < `minSavings`),
    /// in which case the caller transcribes the original with an identity mapping.
    func compact(
        url: URL,
        regions: [SpeechRegion],
        pad: TimeInterval = 0.2,
        gap: TimeInterval = 0.1,
        minSavings: TimeInterval = 1.0
    ) async throws -> CompactionResult? {
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: sampleRate)
        guard !samples.isEmpty else { return nil }
        let totalDuration = Double(samples.count) / sampleRate

        let merged = Self.normalize(regions: regions, pad: pad, totalDuration: totalDuration)
        guard !merged.isEmpty else { return nil }
        let kept = merged.reduce(0) { $0 + ($1.end - $1.start) }
        guard totalDuration - kept >= minSavings else { return nil }

        var compacted: [Float] = []
        compacted.reserveCapacity(Int(kept * sampleRate) + merged.count * Int(gap * sampleRate))
        var map: [TimelineSegment] = []
        var compactedTime: TimeInterval = 0
        let gapSamples = max(0, Int(gap * sampleRate))

        for (index, region) in merged.enumerated() {
            let startIdx = max(0, Int(region.start * sampleRate))
            let endIdx = min(samples.count, Int(region.end * sampleRate))
            guard endIdx > startIdx else { continue }
            if index > 0 {
                compacted.append(contentsOf: repeatElement(0, count: gapSamples))
                compactedTime += gap
            }
            let duration = Double(endIdx - startIdx) / sampleRate
            map.append(TimelineSegment(compactedStart: compactedTime, originalStart: region.start, duration: duration))
            compacted.append(contentsOf: samples[startIdx..<endIdx])
            compactedTime += duration
        }
        guard !map.isEmpty else { return nil }

        let outURL = try Self.write(samples: compacted, sampleRate: sampleRate)
        AppLog.transcription.atInfo.info("vadCompact: \(String(format: "%.1f", totalDuration), privacy: .public)s -> \(String(format: "%.1f", kept), privacy: .public)s speech (\(map.count, privacy: .public) regions)")
        return CompactionResult(url: outURL, map: map)
    }

    /// Remove a compacted temp file. Only touches files in the temp directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Map a compacted-timeline time back to the original timeline. Times in the
    /// inter-region silence gaps snap to the previous region's original end; the
    /// tail snaps to the last region's end.
    static func remap(_ time: TimeInterval, map: [TimelineSegment]) -> TimeInterval {
        guard let first = map.first else { return time }
        if time <= first.compactedStart { return first.originalStart }
        var previousEnd = first.originalStart
        for segment in map {
            if time < segment.compactedStart { return previousEnd }
            let compactedEnd = segment.compactedStart + segment.duration
            if time <= compactedEnd { return segment.originalStart + (time - segment.compactedStart) }
            previousEnd = segment.originalStart + segment.duration
        }
        return previousEnd
    }

    /// Pad, clamp, sort, and merge overlapping regions into a clean ordered set.
    static func normalize(
        regions: [SpeechRegion],
        pad: TimeInterval,
        totalDuration: TimeInterval
    ) -> [SpeechRegion] {
        let padded = regions
            .map { SpeechRegion(start: max(0, $0.start - pad), end: min(totalDuration, $0.end + pad)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard let firstRegion = padded.first else { return [] }

        var merged: [SpeechRegion] = [firstRegion]
        for region in padded.dropFirst() {
            if region.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, region.end)
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    private static func write(samples: [Float], sampleRate: Double) throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_vad_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings)
        let format = outFile.processingFormat

        let chunk = 16_384
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress! + offset, count: count)
                }
            }
            try outFile.write(from: buffer)
            offset += count
        }
        return outURL
    }
}
