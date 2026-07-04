//
//  AudioChunker.swift
//  Kurn
//
//  Splits a long .m4a into fixed-duration chunks via AVAssetExportSession for
//  upload to the Whisper API (which caps request size). Each chunk carries the
//  time offset of its first sample so transcript timestamps can be corrected.
//

import AVFoundation
import Foundation
import os

actor AudioChunker {

    struct Chunk: Sendable {
        let url: URL
        let offset: TimeInterval
    }

    /// Size above which a recording is chunked before upload (~20 MB).
    static let sizeThresholdBytes: Int64 = 20 * 1024 * 1024

    /// Length of each exported chunk.
    static let chunkDuration: TimeInterval = 600 // 10 minutes

    /// Return the file split into chunks in the temporary directory. If the file
    /// is small enough, returns it unmodified as a single chunk at offset 0.
    /// Whisper chunks are capped by both request size and duration: a long but
    /// highly-compressed recording (e.g. 45 min at ~11 MB) is still too long for
    /// a single API call, so we split it into 10-minute chunks even when the
    /// size is below the threshold.
    func chunk(url: URL) async throws -> [Chunk] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let duration = (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atInfo.info("chunk: file \(url.lastPathComponent, privacy: .public) size=\(size, privacy: .public) bytes duration=\(String(format: "%.1f", duration), privacy: .public)s")
        let fitsSize = Int64(size) <= Self.sizeThresholdBytes
        let fitsDuration = duration.isFinite && duration <= Self.chunkDuration
        if fitsSize, fitsDuration {
            AppLog.transcription.atDebug.debug("chunk: \(size, privacy: .public) bytes / \(String(format: "%.1f", duration), privacy: .public)s <= thresholds, single chunk")
            return [Chunk(url: url, offset: 0)]
        }
        AppLog.transcription.atDebug.debug("chunk: \(size, privacy: .public) bytes / \(String(format: "%.1f", duration), privacy: .public)s exceeds thresholds, splitting…")
        return try await split(url: url, knownDuration: duration)
    }

    /// Split by duration regardless of file size. Used by the on-device Speech
    /// engine, where the constraint is the length a single recognition task can
    /// reliably handle (a 2h file in one `SFSpeechRecognitionTask` is fragile),
    /// not an upload size cap. Files no longer than one chunk come back whole.
    func chunkByDuration(url: URL) async throws -> [Chunk] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let asset = AVURLAsset(url: url)
        let totalSeconds = try await CMTimeGetSeconds(asset.load(.duration))
        AppLog.transcription.atInfo.info("chunkByDuration: file \(url.lastPathComponent, privacy: .public) size=\(size, privacy: .public) bytes duration=\(String(format: "%.1f", totalSeconds), privacy: .public)s")
        guard totalSeconds.isFinite, totalSeconds > Self.chunkDuration else {
            return [Chunk(url: url, offset: 0)]
        }
        AppLog.transcription.atDebug.debug("chunk: \(totalSeconds, privacy: .public)s > \(Self.chunkDuration, privacy: .public)s, splitting by duration…")
        return try await split(url: url, knownDuration: totalSeconds)
    }

    private func split(url: URL, knownDuration: TimeInterval) async throws -> [Chunk] {
        let exportStart = Date()
        let asset = AVURLAsset(url: url)
        let totalSeconds = knownDuration.isFinite && knownDuration > 0
            ? knownDuration
            : (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            AppLog.transcription.atError.error("chunk: split failed, duration is invalid or zero")
            return [Chunk(url: url, offset: 0)]
        }

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

        while start < totalSeconds {
            let length = min(Self.chunkDuration, totalSeconds - start)
            let outURL = tmpDir.appendingPathComponent(
                "kurn_chunk_\(UUID().uuidString)_\(index).m4a"
            )
            try? FileManager.default.removeItem(at: outURL)

            let chunkStart = Date()
            do {
                try await export(
                    asset: asset,
                    to: outURL,
                    range: CMTimeRange(
                        start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: length, preferredTimescale: 600)
                    )
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
            let chunkSize = (try? outURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let chunkDuration = (try? await AVURLAsset(url: outURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
            AppLog.transcription.atInfo.info("chunk: exported \(index + 1, privacy: .public) offset=\(String(format: "%.1f", start), privacy: .public)s length=\(String(format: "%.1f", length), privacy: .public)s duration=\(String(format: "%.1f", chunkDuration), privacy: .public)s size=\(chunkSize, privacy: .public) bytes in \(Date().timeIntervalSince(chunkStart), privacy: .public)s")
            guard chunkSize > 0 else {
                AppLog.transcription.atError.error("chunk: exported chunk \(index + 1, privacy: .public) is empty, discarding")
                try? FileManager.default.removeItem(at: outURL)
                throw AppError.audioError(
                    NSLocalizedString("error.export_failed", comment: "Export failed")
                )
            }
            chunks.append(Chunk(url: outURL, offset: start))
            start += length
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

    private func export(
        asset: AVURLAsset,
        to outURL: URL,
        range: CMTimeRange
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AppError.audioError(
                NSLocalizedString("error.export_session", comment: "Export session unavailable")
            )
        }
        session.outputURL = outURL
        session.outputFileType = .m4a
        session.timeRange = range

        // AVAssetExportSession is not Sendable; box it so the completion handler
        // captures only Sendable values under Swift 6 strict concurrency. The
        // completion runs after export finishes, so reading status is safe.
        let box = ExportBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(
                        throwing: AppError.audioError(
                            box.session.error?.localizedDescription
                                ?? NSLocalizedString("error.export_failed", comment: "Export failed")
                        )
                    )
                default:
                    continuation.resume(
                        throwing: AppError.audioError(
                            NSLocalizedString("error.export_failed", comment: "Export failed")
                        )
                    )
                }
            }
        }
    }
}

/// Sendable wrapper so the export session can cross into the completion handler
/// without tripping Swift 6 data-race checks.
private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
