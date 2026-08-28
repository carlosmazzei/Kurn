//
//  AudioChunker.swift
//  Kurn
//
//  Splits a long .m4a into fixed-duration chunks via AVAssetExportSession for
//  upload to the Whisper API (which caps request size). Each chunk carries the
//  time offset of its first sample so transcript timestamps can be corrected.
//
//  Chunking **slices**, it does not re-encode: the export runs with
//  `AVAssetExportPresetPassthrough`, so a chunk inherits whatever format the
//  source has. That matters because the audio reaching this type has already
//  been rendered down to 16kHz mono at 32kbps by `AudioPreprocessor`, and the
//  fixed `AVAssetExportPresetAppleM4A` would re-encode it *up* to the preset's
//  own settings — inflating every cloud upload and temp file, and spending a
//  lossy generation, for detail no consumer reads back. See `preferredPreset`.
//
//  Exporting goes through `AVAssetExportSession.export(to:as:)`, which is async
//  and throws. The older `exportAsynchronously` + `status`/`error` polling was
//  deprecated in iOS 18, and its completion handler was the only reason this
//  file needed a `@unchecked Sendable` box to carry the non-Sendable session
//  across isolation under Swift 6.
//

import AVFoundation
import Foundation
import KurnCore
import os

actor AudioChunker {

    struct Chunk: Sendable {
        let url: URL
        let offset: TimeInterval
    }

    /// Size above which a recording is chunked before upload (~20 MB).
    static let sizeThresholdBytes: Int64 = 20 * 1024 * 1024

    /// Default length used for Whisper uploads.
    static let defaultChunkDuration: TimeInterval = 600 // 10 minutes

    /// Per-consumer duration cap. Apple Speech needs substantially shorter
    /// recognition tasks than Whisper's upload path.
    private let chunkDuration: TimeInterval

    init(chunkDuration: TimeInterval = defaultChunkDuration) {
        self.chunkDuration = chunkDuration
    }

    /// Return the file split into chunks in the temporary directory. If the file
    /// is small enough, returns it unmodified as a single chunk at offset 0.
    /// Whisper chunks are capped by both request size and duration: a long but
    /// highly-compressed recording (e.g. 45 min at ~11 MB) is still too long for
    /// a single API call, so we split it into 10-minute chunks even when the
    /// size is below the threshold.
    ///
    /// `cutPoints` are times the caller would rather cut at — silences, on the
    /// same timeline as the file. See `ChunkBoundary`.
    func chunk(url: URL, cutPoints: [TimeInterval] = []) async throws -> [Chunk] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let duration = (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atInfo.info("chunk: file \(url.lastPathComponent, privacy: .public) size=\(size, privacy: .public) bytes duration=\(String(format: "%.1f", duration), privacy: .public)s")
        let fitsSize = Int64(size) <= Self.sizeThresholdBytes
        let fitsDuration = duration.isFinite && duration <= chunkDuration
        if fitsSize, fitsDuration {
            AppLog.transcription.atDebug.debug("chunk: \(size, privacy: .public) bytes / \(String(format: "%.1f", duration), privacy: .public)s <= thresholds, single chunk")
            return [Chunk(url: url, offset: 0)]
        }
        AppLog.transcription.atDebug.debug("chunk: \(size, privacy: .public) bytes / \(String(format: "%.1f", duration), privacy: .public)s exceeds thresholds, splitting…")
        return try await split(url: url, knownDuration: duration, cutPoints: cutPoints)
    }

    /// Split by duration regardless of file size. Used by `WhisperCppTranscriber`,
    /// where the constraint is resident memory rather than an upload size cap:
    /// `whisper_full` takes the whole clip as one `[Float]`, so a two-hour file
    /// would be ~460MB of samples. Files no longer than one chunk come back whole.
    func chunkByDuration(url: URL, cutPoints: [TimeInterval] = []) async throws -> [Chunk] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let asset = AVURLAsset(url: url)
        let totalSeconds = try await CMTimeGetSeconds(asset.load(.duration))
        AppLog.transcription.atInfo.info("chunkByDuration: file \(url.lastPathComponent, privacy: .public) size=\(size, privacy: .public) bytes duration=\(String(format: "%.1f", totalSeconds), privacy: .public)s")
        guard totalSeconds.isFinite, totalSeconds > chunkDuration else {
            return [Chunk(url: url, offset: 0)]
        }
        AppLog.transcription.atDebug.debug("chunk: \(totalSeconds, privacy: .public)s > \(self.chunkDuration, privacy: .public)s, splitting by duration…")
        return try await split(url: url, knownDuration: totalSeconds, cutPoints: cutPoints)
    }

    private func split(
        url: URL,
        knownDuration: TimeInterval,
        cutPoints: [TimeInterval] = []
    ) async throws -> [Chunk] {
        let exportStart = Date()
        let asset = AVURLAsset(url: url)
        // AVAssetExportSession silently produces an empty file if the asset's
        // tracks haven't been loaded yet when `knownDuration` short-circuits the
        // `.duration` load below, this asset's properties are otherwise never
        // resolved before being handed to the export session.
        _ = try? await asset.load(.tracks)
        let totalSeconds = knownDuration.isFinite && knownDuration > 0
            ? knownDuration
            : (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            AppLog.transcription.atError.error("chunk: split failed, duration is invalid or zero")
            return [Chunk(url: url, offset: 0)]
        }

        let preset = await Self.preferredPreset(for: asset)

        var chunks: [Chunk] = []
        var completed = false
        var start: TimeInterval = 0
        var index = 0
        let tmpDir = FileManager.default.temporaryDirectory
        defer {
            if !completed, !chunks.isEmpty {
                cleanup(chunks)
            }
        }

        let candidates = cutPoints.filter { $0.isFinite && $0 > 0 && $0 < totalSeconds }.sorted()
        if !candidates.isEmpty {
            AppLog.transcription.atDebug.debug("chunk: \(candidates.count, privacy: .public) silence candidate(s) available for cutting")
        }

        while start < totalSeconds {
            let end = ChunkBoundary.end(
                start: start,
                nominalEnd: min(start + chunkDuration, totalSeconds),
                total: totalSeconds,
                candidates: candidates
            )
            let length = end - start
            // Belt and braces: a non-positive length would loop forever. The
            // boundary chooser cannot produce one, and this makes that a bug
            // rather than a hang if it ever does.
            guard length > 0 else { break }
            let outURL = tmpDir.appendingPathComponent(
                "kurn_chunk_\(UUID().uuidString)_\(index).m4a"
            )
            try? FileManager.default.removeItem(at: outURL)

            let chunkStart = Date()
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            let chunkSize: Int
            do {
                chunkSize = try await exportRetryingIfEmpty(
                    asset: asset,
                    to: outURL,
                    range: range,
                    preset: preset
                )
            } catch {
                // Remove the partially-written file for the failed chunk so it
                // doesn't become an orphan when the caller's defer cleans up the
                // already-successful chunks.
                try? FileManager.default.removeItem(at: outURL)
                throw error
            }
            // In-flight class (not `.completeUnlessOpen`): chunk files must be
            // readable with the device locked so a background Whisper run can
            // keep feeding uploads; they're deleted when the run finishes.
            RecordingProtection.applyInFlight(to: outURL)
            // Named apart from `self.chunkDuration`: with a passthrough export the
            // two genuinely differ, so the shadowing this used to do would hide a
            // real distinction.
            let actualDuration = (try? await AVURLAsset(url: outURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
            AppLog.transcription.atInfo.info("chunk: exported \(index + 1, privacy: .public) offset=\(String(format: "%.1f", start), privacy: .public)s length=\(String(format: "%.1f", length), privacy: .public)s duration=\(String(format: "%.1f", actualDuration), privacy: .public)s size=\(chunkSize, privacy: .public) bytes in \(Date().timeIntervalSince(chunkStart), privacy: .public)s")
            // Offset is the *requested* start, deliberately — not a running sum of
            // `actualDuration`. A passthrough export cuts on compressed-frame
            // boundaries, so a chunk's content can begin up to one AAC frame
            // (1024 samples, ~64ms at 16kHz) before `start`. That makes `start`
            // wrong by a bounded, non-cumulative amount, while summing measured
            // durations would fold the same slop in once per chunk and drift
            // forward across the whole meeting.
            chunks.append(Chunk(url: outURL, offset: start))
            start = end
            index += 1
        }

        completed = true
        AppLog.transcription.atNotice.notice("chunk: split into \(chunks.count, privacy: .public) chunk(s) in \(Date().timeIntervalSince(exportStart), privacy: .public)s")
        return chunks
    }

    /// Remove temporary chunk files. Safe to call with the original recording's
    /// chunk list — it skips anything not in the temp directory.
    func cleanup(_ chunks: [Chunk]) {
        let tmp = FileManager.default.temporaryDirectory.path
        var removed = 0
        for chunk in chunks where chunk.url.path.hasPrefix(tmp) {
            if FileManager.default.fileExists(atPath: chunk.url.path) {
                try? FileManager.default.removeItem(at: chunk.url)
                removed += 1
            }
        }
        if removed > 0 {
            AppLog.transcription.atDebug.debug("chunk: cleaned up \(removed, privacy: .public) temp chunk(s)")
        }
    }

    /// `AVAssetExportSession` can report `.completed` while writing a 0-byte
    /// file under transient resource contention (seen under heavily parallel
    /// test runs); one retry has proven reliable, so treat an empty result as
    /// retryable rather than failing the whole chunk immediately.
    private func exportRetryingIfEmpty(
        asset: AVURLAsset,
        to outURL: URL,
        range: CMTimeRange,
        preset: String
    ) async throws -> Int {
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: outURL)
            try await export(asset: asset, to: outURL, range: range, preset: preset)
            let size = (try? outURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0 {
                return size
            }
            AppLog.transcription.atError.error("chunk: export produced an empty file (attempt \(attempt + 1, privacy: .public))")
        }
        try? FileManager.default.removeItem(at: outURL)
        throw AppError.audioError(
            NSLocalizedString("error.export_failed", comment: "Export failed")
        )
    }

    /// Prefer passthrough: chunking should slice the file, not re-encode it.
    /// `AVAssetExportPresetAppleM4A`'s sample rate, channel count and bit rate
    /// belong to the preset, not to the source, so it would re-encode the 16kHz
    /// mono 32kbps cleaned file up to them — inflating every upload and temp file,
    /// and burning a lossy generation, for detail nothing downstream reads back.
    ///
    /// Passthrough needs the output container to accept the source's codec, so
    /// this asks AVFoundation rather than assuming, and keeps the old preset as
    /// the fallback for anything it can't copy.
    ///
    /// `determineCompatibility` is bridged only in its completion-handler form —
    /// there is no `async` overload to await — so it is wrapped here. The handler
    /// reports a plain `Bool` with no error channel, hence the non-throwing
    /// continuation.
    private static func preferredPreset(for asset: AVURLAsset) async -> String {
        let compatible = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAssetExportSession.determineCompatibility(
                ofExportPreset: AVAssetExportPresetPassthrough,
                with: asset,
                outputFileType: .m4a
            ) { isCompatible in
                continuation.resume(returning: isCompatible)
            }
        }
        guard compatible else {
            AppLog.transcription.atNotice.notice("chunk: passthrough unavailable for this asset, re-encoding with the M4A preset")
            return AVAssetExportPresetAppleM4A
        }
        AppLog.transcription.atDebug.debug("chunk: exporting with passthrough (no re-encode)")
        return AVAssetExportPresetPassthrough
    }

    private func export(
        asset: AVURLAsset,
        to outURL: URL,
        range: CMTimeRange,
        preset: String
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw AppError.audioError(
                NSLocalizedString("error.export_session", comment: "Export session unavailable")
            )
        }
        session.timeRange = range

        do {
            try await session.export(to: outURL, as: .m4a)
        } catch is CancellationError {
            // Let cooperative cancellation through rather than reporting it as an
            // audio failure: the pipeline cancels chunking when the user stops a
            // run, and that shouldn't surface an error alert.
            throw CancellationError()
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }
}

// `ChunkBoundary` now lives in the KurnCore package
// (`Sources/KurnCore/Pipeline/ChunkBoundary.swift`), since it's pure
// Foundation logic with no AVFoundation dependency. This file gains
// `import KurnCore` above for it, plus `SpeechRegion`/`TimelineSegment`.
