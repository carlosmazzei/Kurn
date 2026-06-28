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
/// compactor, `FluidAudioVAD`, and `SpeakerDiarizer`.
enum VADAudioLoader {
    /// Decode `url` to mono Float samples at `sampleRate` using an offline
    /// `AVAudioEngine` render (the same mechanism `AudioPreprocessor` uses).
    ///
    /// This deliberately does NOT use `AVAudioFile.read(into:)` or
    /// `AVAudioConverter`: on device, both of those decode paths fail on the
    /// app's compressed AAC `.m4a` files with a generic `erro 0`
    /// (`Foundation._GenericObjCError`), which silently broke both VAD and
    /// diarization (collapsing to a single speaker / whole-clip region). The
    /// engine's player-node render path decodes the very same files reliably —
    /// `AudioPreprocessor` reads them this way every run without error.
    static func monoSamples(url: URL, sampleRate: Double) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let totalInputFrames = inputFile.length
        guard totalInputFrames > 0, inputFormat.sampleRate > 0 else { return [] }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // The mixer/output path resamples and downmixes to the manual-rendering
        // format (mono @ `sampleRate`), so connect with the source's own format.
        engine.connect(player, to: engine.mainMixerNode, format: inputFormat)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: maxFrames)
        try engine.start()
        // Completion-handler overload (not the `async` one): in offline rendering
        // the file is consumed by the render loop below, so awaiting playback
        // completion would deadlock. Matches `AudioPreprocessor`.
        player.scheduleFile(inputFile, at: nil, completionHandler: nil)
        player.play()

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames
        ) else {
            engine.stop()
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }

        let ratio = sampleRate / inputFormat.sampleRate
        let expectedOutFrames = AVAudioFramePosition(Double(totalInputFrames) * ratio)
        var output: [Float] = []
        output.reserveCapacity(Int(max(0, expectedOutFrames)))

        renderLoop: while engine.manualRenderingSampleTime < expectedOutFrames {
            let remaining = expectedOutFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(Int64(maxFrames), remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                if let channel = renderBuffer.floatChannelData, renderBuffer.frameLength > 0 {
                    output.append(
                        contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(renderBuffer.frameLength))
                    )
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext, .error:
                break renderLoop
            @unknown default:
                break renderLoop
            }
        }

        player.stop()
        engine.stop()
        return output
    }
}

struct VADAudioCompactor {

    private let sampleRate: Double = 16_000

    /// Build the compacted file + timeline map, or `nil` when compaction isn't
    /// worthwhile (no regions, regions ~cover the clip, or trim saves < `minSavings`),
    /// in which case the caller transcribes the original with an identity mapping.
    ///
    /// Streams the source file one region at a time — seek, convert to 16 kHz
    /// mono, write straight to the output — so peak memory stays at a single
    /// read buffer instead of loading the whole clip (and its trimmed copy) into
    /// `[Float]` arrays. That double-buffering pushed long recordings past the
    /// process memory limit on device.
    func compact(
        url: URL,
        regions: [SpeechRegion],
        pad: TimeInterval = 0.2,
        gap: TimeInterval = 0.1,
        minSavings: TimeInterval = 1.0
    ) async throws -> CompactionResult? {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0, file.length > 0 else { return nil }
        let totalDuration = Double(file.length) / inFormat.sampleRate

        let merged = Self.normalize(regions: regions, pad: pad, totalDuration: totalDuration)
        guard !merged.isEmpty else { return nil }
        let kept = merged.reduce(0) { $0 + ($1.end - $1.start) }
        guard totalDuration - kept >= minSavings else { return nil }

        let outURL = Self.tempURL()
        let outFile = try AVAudioFile(forWriting: outURL, settings: Self.aacSettings(sampleRate: sampleRate))
        let outFormat = outFile.processingFormat

        var map: [TimelineSegment] = []
        var compactedTime: TimeInterval = 0
        let gapSamples = max(0, Int(gap * sampleRate))

        do {
            for region in merged {
                // Skip degenerate regions before writing a seam gap, so we never
                // emit an orphan gap with no speech after it.
                guard Int(region.end * sampleRate) - Int(region.start * sampleRate) > 0 else { continue }
                if !map.isEmpty {
                    try Self.writeSilence(frames: gapSamples, to: outFile, format: outFormat)
                    compactedTime += gap
                }
                let written = try Self.streamRegion(
                    file: file, startSec: region.start, endSec: region.end, to: outFile
                )
                guard written > 0 else { continue }
                let duration = Double(written) / sampleRate
                map.append(TimelineSegment(compactedStart: compactedTime, originalStart: region.start, duration: duration))
                compactedTime += duration
            }
        } catch {
            cleanup(outURL)
            throw error
        }
        guard !map.isEmpty else {
            cleanup(outURL)
            return nil
        }

        AppLog.transcription.atInfo.info("vadCompact: \(String(format: "%.1f", totalDuration), privacy: .public)s -> \(String(format: "%.1f", kept), privacy: .public)s speech (\(map.count, privacy: .public) regions)")
        return CompactionResult(url: outURL, map: map)
    }

    /// Write the first `seconds` of `url` to a temp 16 kHz-mono file, or `nil`
    /// when the clip is already shorter (the caller uses the original). Lets
    /// language detection run a short ASR pass instead of transcribing the whole
    /// recording just to classify its language.
    static func prefixClip(url: URL, seconds: TimeInterval, sampleRate: Double = 16_000) throws -> URL? {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0, file.length > 0 else { return nil }
        let totalDuration = Double(file.length) / inFormat.sampleRate
        guard totalDuration > seconds else { return nil }

        let outURL = tempURL()
        let outFile = try AVAudioFile(forWriting: outURL, settings: aacSettings(sampleRate: sampleRate))
        do {
            let written = try streamRegion(file: file, startSec: 0, endSec: seconds, to: outFile)
            guard written > 0 else {
                try? FileManager.default.removeItem(at: outURL)
                return nil
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
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

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_vad_\(UUID().uuidString).m4a")
    }

    private static func aacSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    /// Stream `[startSec, endSec)` of `file` to `outFile`, converting to mono at
    /// `targetSampleRate`, and return the number of frames written. Reads in
    /// small chunks and writes straight through, so no whole-region buffer is
    /// ever materialized.
    private static func streamRegion(
        file: AVAudioFile,
        startSec: TimeInterval,
        endSec: TimeInterval,
        to outFile: AVAudioFile
    ) throws -> Int {
        let inFormat = file.processingFormat
        let inSR = inFormat.sampleRate
        let outFormat = outFile.processingFormat
        let targetSampleRate = outFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, startSec * inSR))
        let endFrame = AVAudioFramePosition(min(Double(file.length), endSec * inSR))
        guard endFrame > startFrame else { return 0 }
        file.framePosition = startFrame
        guard
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 16_384)
        else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }

        var remaining = endFrame - startFrame
        var produced = 0
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(Int64(16_384), remaining))
            try file.read(into: inBuf, frameCount: toRead)
            let got = inBuf.frameLength
            if got == 0 { break }
            remaining -= AVAudioFramePosition(got)

            let ratio = targetSampleRate / inSR
            let capacity = AVAudioFrameCount(Double(got) * ratio) + 1_024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }

            // The converter's input block is `@Sendable` but runs synchronously
            // inside `convert` on this thread, so this one-shot "feed once" flag
            // is not actually shared across threads.
            nonisolated(unsafe) var provided = false
            var convError: NSError?
            _ = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw AppError.audioError(convError.localizedDescription) }
            if outBuf.frameLength > 0 {
                try outFile.write(from: outBuf)
                produced += Int(outBuf.frameLength)
            }
        }
        return produced
    }

    /// Append `frames` of silence to `outFile`, chunked so no large zero buffer
    /// is allocated.
    private static func writeSilence(frames: Int, to outFile: AVAudioFile, format: AVAudioFormat) throws {
        guard frames > 0 else { return }
        var remaining = frames
        let chunk = 16_384
        while remaining > 0 {
            let count = min(chunk, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData {
                channel[0].update(repeating: 0, count: count)
            }
            try outFile.write(from: buffer)
            remaining -= count
        }
    }
}
