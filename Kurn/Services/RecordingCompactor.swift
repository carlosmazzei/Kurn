//
//  RecordingCompactor.swift
//  Kurn
//
//  Re-encodes already-transcribed recordings down to the app's speech storage
//  format, reclaiming the space taken by meetings captured before that format
//  existed (the recorder used to encode at the microphone's native sample rate,
//  spending bits on a band nothing reads back).
//
//  This is the one destructive operation in the app that isn't an explicit
//  delete, so every step is defensive: the re-encode goes to a temporary file,
//  the result is verified against the original, and only then is it swapped in
//  atomically. A failure at any point leaves the original untouched. Nothing here
//  runs automatically — it is driven by the user from Settings → Storage.
//
//  Transcripts, summaries, speakers and the semantic index are unaffected: none
//  of them is derived from the audio after the fact.
//

import AVFoundation
import Foundation
import os

struct RecordingCompactor: Sendable {
    /// What compaction needs to know about one recording, free of SwiftData and
    /// AVFoundation so candidate selection stays pure and testable.
    struct Candidate: Sendable, Equatable {
        let fileName: String
        let duration: TimeInterval
        let fileSize: Int64
    }

    /// A recording is only re-encoded when it is at least this much fatter than
    /// the target. Without the margin, a file already at the target bit rate
    /// would be re-encoded for a rounding error's worth of space — paying a
    /// generation of lossy loss for nothing.
    static let minimumExcessRatio = 1.15

    /// Bit rate the re-encode targets. Defaults to the user's chosen quality so
    /// compaction lands on the same setting new recordings use.
    let targetBitRate: Int

    init(targetBitRate: Int = AudioQuality.standard.bitRate) {
        self.targetBitRate = targetBitRate
    }

    // MARK: - Candidate selection (pure)

    /// Whether re-encoding would save enough to be worth a lossy generation.
    /// `fileSize == 0` means the size is unknown (a row not yet backfilled), and
    /// unknown is treated as "leave it alone".
    static func isWorthCompacting(
        duration: TimeInterval,
        fileSize: Int64,
        targetBitRate: Int
    ) -> Bool {
        guard duration > 0, fileSize > 0, targetBitRate > 0 else { return false }
        let effectiveBitRate = Double(fileSize) * 8 / duration
        return effectiveBitRate > Double(targetBitRate) * minimumExcessRatio
    }

    /// Bytes `candidate` would give back, floored at 0.
    static func estimatedSavings(for candidate: Candidate, targetBitRate: Int) -> Int64 {
        guard isWorthCompacting(
            duration: candidate.duration,
            fileSize: candidate.fileSize,
            targetBitRate: targetBitRate
        ) else { return 0 }
        let projected = Int64(candidate.duration * Double(targetBitRate) / 8)
        return max(0, candidate.fileSize - projected)
    }

    /// Filter to the recordings worth re-encoding, largest saving first so an
    /// interrupted run has still reclaimed the most it could.
    func candidates(from all: [Candidate]) -> [Candidate] {
        all
            .filter {
                Self.isWorthCompacting(
                    duration: $0.duration,
                    fileSize: $0.fileSize,
                    targetBitRate: targetBitRate
                )
            }
            .sorted {
                Self.estimatedSavings(for: $0, targetBitRate: targetBitRate)
                    > Self.estimatedSavings(for: $1, targetBitRate: targetBitRate)
            }
    }

    /// Total bytes a run over `candidates` is expected to reclaim.
    func estimatedSavings(for candidates: [Candidate]) -> Int64 {
        candidates.reduce(0) { $0 + Self.estimatedSavings(for: $1, targetBitRate: targetBitRate) }
    }

    // MARK: - Compaction

    /// Re-encode one recording in place. Returns the bytes reclaimed, or 0 when
    /// the recording was left as it was (already small enough, or the result
    /// failed verification). Only throws for conditions that should stop the
    /// whole run: cancellation and resource exhaustion.
    func compact(fileName: String) async throws -> Int64 {
        let originalURL = AudioFileStore.resolveURL(fileName: fileName)
        let originalSize = AudioFileStore.byteSize(fileName: fileName)
        guard originalSize > 0 else { return 0 }

        // Compaction writes a whole second copy before swapping, so it needs the
        // same disk headroom a transcription does.
        try await ResourceGuard.requireTranscriptionHeadroom()

        guard let source = try? AVAudioFile(forReading: originalURL),
              source.processingFormat.sampleRate > 0,
              source.length > 0 else {
            AppLog.recorder.atError.error("compact: \(fileName, privacy: .public) is not readable; leaving it alone")
            return 0
        }
        let inputSampleRate = source.processingFormat.sampleRate
        let inputDuration = Double(source.length) / inputSampleRate

        // Never upsample: a recording captured over a narrowband Bluetooth route
        // is already below the storage rate, and resampling up would cost bytes.
        let outputSampleRate = min(AudioRecorderService.storageSampleRate, inputSampleRate)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_compact_\(UUID().uuidString).m4a")
        var swapped = false
        defer {
            if !swapped { try? FileManager.default.removeItem(at: tempURL) }
        }

        guard try await reencode(
            from: originalURL,
            to: tempURL,
            outputSampleRate: outputSampleRate,
            expectedDuration: inputDuration
        ) else {
            return 0
        }

        let newSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard newSize > 0, Int64(newSize) < originalSize else {
            AppLog.recorder.atInfo.info("compact: \(fileName, privacy: .public) did not get smaller (\(originalSize, privacy: .public) -> \(newSize, privacy: .public)); keeping the original")
            return 0
        }

        // Set the protection class on the replacement before it lands in the
        // recordings directory, so the file is never briefly readable without
        // the passcode.
        RecordingProtection.apply(to: tempURL)
        do {
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)
        } catch {
            AppLog.recorder.atError.error("compact: swap failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
        swapped = true
        // Re-apply after the swap: `replaceItemAt` does not promise to carry the
        // attribute across, and a recording without it would be readable from a
        // backup extraction.
        RecordingProtection.apply(to: AudioFileStore.resolveURL(fileName: fileName))

        let saved = originalSize - Int64(newSize)
        AppLog.recorder.atNotice.notice("compact: \(fileName, privacy: .public) \(originalSize, privacy: .public) -> \(newSize, privacy: .public) bytes (saved \(saved, privacy: .public))")
        return saved
    }

    /// Decode `source` and write it back out at the target format. Returns false
    /// when the result should be discarded rather than swapped in.
    private func reencode(
        from source: URL,
        to destination: URL,
        outputSampleRate: Double,
        expectedDuration: TimeInterval
    ) async throws -> Bool {
        let failure = AppError.audioError(
            NSLocalizedString("error.audio_compaction", comment: "Recording could not be compacted")
        )
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: outputSampleRate) else {
            throw failure
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outFile = try AVAudioFile(forWriting: destination, settings: settings)

        // No DSP chain: compaction must not alter the audio beyond the resample
        // and re-encode. In particular it must not apply the ASR cleanup chain —
        // the diarizer reads this file and depends on natural timbre.
        let renderer = OfflineAudioRenderer(
            outputFormat: outputFormat,
            failure: failure,
            logLabel: "compact"
        )

        let renderedFrames = try await renderer.render(url: source) { buffer in
            try Task.checkCancellation()
            try outFile.write(from: buffer)
        }

        // Verify the render itself before the encoder's padding can blur the
        // numbers: a truncated render (source sample table ending early, a write
        // that failed) shows up here as a large frame shortfall.
        let expectedFrames = expectedDuration * outputSampleRate
        guard expectedFrames > 0,
              Double(renderedFrames) >= expectedFrames - Self.renderedFrameTolerance(expectedFrames) else {
            AppLog.recorder.atError.error("compact: render came up short (\(renderedFrames, privacy: .public) of ~\(Int(expectedFrames), privacy: .public) frames); discarding")
            return false
        }

        return verify(destination, against: expectedDuration)
    }

    /// How many frames a render may come up short by and still be accepted. The
    /// resampler holds back its filter length at end of stream, so there is
    /// always a small shortfall; the absolute floor keeps a short clip from being
    /// rejected over it, while the 2% share keeps the check meaningful on a long
    /// meeting. Real truncation loses far more than either.
    private static func renderedFrameTolerance(_ expectedFrames: Double) -> Double {
        max(expectedFrames * 0.02, 4096)
    }

    /// Independently re-open the written file and check it decodes to about the
    /// right length. This catches a container that was never finalized, which the
    /// frame count above cannot see.
    private func verify(_ url: URL, against expectedDuration: TimeInterval) -> Bool {
        guard let written = try? AVAudioFile(forReading: url),
              written.processingFormat.sampleRate > 0 else {
            AppLog.recorder.atError.error("compact: result is not readable; discarding")
            return false
        }
        let writtenDuration = Double(written.length) / written.processingFormat.sampleRate
        // Tolerant on the low side only, and not tighter than a fraction of a
        // second: AAC adds encoder priming/padding, which on a short clip is a
        // measurable share of the duration without anything being wrong.
        let allowedShortfall = max(expectedDuration * 0.02, 0.5)
        guard writtenDuration >= expectedDuration - allowedShortfall else {
            AppLog.recorder.atError.error("compact: result is \(writtenDuration, privacy: .public)s vs expected \(expectedDuration, privacy: .public)s; discarding")
            return false
        }
        return true
    }
}
