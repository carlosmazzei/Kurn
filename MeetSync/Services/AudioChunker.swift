//
//  AudioChunker.swift
//  MeetSync
//
//  Splits a long .m4a into fixed-duration chunks via AVAssetExportSession for
//  upload to the Whisper API (which caps request size). Each chunk carries the
//  time offset of its first sample so transcript timestamps can be corrected.
//

import AVFoundation
import Foundation

actor AudioChunker {

    struct Chunk: Sendable {
        let url: URL
        let offset: TimeInterval
    }

    /// Size above which a recording is chunked before upload (~20 MB).
    static let sizeThresholdBytes: Int64 = 20 * 1024 * 1024

    private let chunkDuration: TimeInterval = 600 // 10 minutes

    /// Return the file split into chunks in the temporary directory. If the file
    /// is small enough, returns it unmodified as a single chunk at offset 0.
    func chunk(url: URL) async throws -> [Chunk] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if Int64(size) <= Self.sizeThresholdBytes {
            return [Chunk(url: url, offset: 0)]
        }

        let asset = AVURLAsset(url: url)
        let totalSeconds = try await CMTimeGetSeconds(asset.load(.duration))
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            return [Chunk(url: url, offset: 0)]
        }

        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        var index = 0
        let tmpDir = FileManager.default.temporaryDirectory

        while start < totalSeconds {
            let length = min(chunkDuration, totalSeconds - start)
            let outURL = tmpDir.appendingPathComponent(
                "meetsync_chunk_\(UUID().uuidString)_\(index).m4a"
            )
            try? FileManager.default.removeItem(at: outURL)

            try await export(
                asset: asset,
                to: outURL,
                range: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: length, preferredTimescale: 600)
                )
            )
            chunks.append(Chunk(url: outURL, offset: start))
            start += length
            index += 1
        }

        return chunks
    }

    /// Remove temporary chunk files. Safe to call with the original recording's
    /// chunk list — it skips anything not in the temp directory.
    func cleanup(_ chunks: [Chunk]) {
        let tmp = FileManager.default.temporaryDirectory.path
        for chunk in chunks where chunk.url.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: chunk.url)
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
