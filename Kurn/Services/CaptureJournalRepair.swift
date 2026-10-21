//
//  CaptureJournalRepair.swift
//  Kurn
//
//  Rebuilds a recording's `.m4a` from its `CaptureJournal` when the process
//  that was capturing it died before closing the file. The rebuild is a remux
//  (passthrough export of the ADTS frames into an MPEG-4 container) when
//  AVFoundation manages one, and otherwise a re-encode — see `exportToM4A`.
//
//  The rebuild is written to a temporary file and verified decodable before it
//  replaces anything, and it never replaces a recording that is already
//  readable: a cleanly closed `.m4a` is the authoritative copy, and its journal
//  is simply discarded by `RecordingFileFinalizer`. The journal itself is kept
//  until that finalizer accepts the rebuilt file.
//

import AVFoundation
import Foundation
import KurnCore

enum CaptureJournalRepair {
    /// Prefix of the in-flight rebuild in the temporary directory, swept by
    /// `TempFileCleaner` if a rebuild is itself interrupted.
    static let tempFilePrefix = "kurn_capture_"

    typealias Exporter = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    enum Outcome: Equatable, Sendable {
        /// No journal on disk for this recording.
        case noJournal
        /// The recording is already readable; nothing was replaced.
        case notNeeded
        /// The recording was rebuilt from its journal.
        case rebuilt
        /// The journal exists but could not be turned into a readable file.
        /// The journal and the original are left untouched.
        case failed
    }

    static func rebuild(fileName: String, export: Exporter = exportToM4A) async -> Outcome {
        let fm = FileManager.default
        let journalURL = CaptureJournal.url(for: fileName)
        let journalSize = (try? journalURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fm.fileExists(atPath: journalURL.path), journalSize > 0 else { return .noJournal }

        let destination = AudioFileStore.resolveURL(fileName: fileName)
        if isReadable(destination) { return .notNeeded }

        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("\(tempFilePrefix)\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tempURL) }
        do {
            try await export(journalURL, tempURL)
        } catch {
            AppLog.recorder.atError.error(
                "capture journal rebuild: export failed file=\(fileName, privacy: .public) code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            return .failed
        }
        guard isReadable(tempURL) else {
            AppLog.recorder.atError.error("capture journal rebuild: rebuilt file is not decodable file=\(fileName, privacy: .public)")
            return .failed
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                // The original is the undecodable container the killed process
                // left: the same encoded audio as the journal, minus the sample
                // table that would have made it readable.
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                let directory = try AudioFileStore.ensureRecordingsDirectory()
                try fm.moveItem(at: tempURL, to: directory.appendingPathComponent(fileName))
            }
        } catch {
            AppLog.recorder.atError.error(
                "capture journal rebuild: swap failed file=\(fileName, privacy: .public) code=\(error.publicLogCode, privacy: .public)"
            )
            return .failed
        }
        RecordingProtection.apply(to: AudioFileStore.resolveURL(fileName: fileName))
        AppLog.recorder.atNotice.notice("capture journal rebuild: rebuilt file=\(fileName, privacy: .public)")
        return .rebuilt
    }

    /// The same readability bar `RecordingFileFinalizer` applies.
    static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return false }
        return file.length > 0
    }

    /// Remux the ADTS journal into an `.m4a`, falling back to a re-encode.
    ///
    /// The passthrough export keeps the encoded frames as they are, but the
    /// rebuild through it alone came back unusable for an ADTS source on the CI
    /// simulator, so a throw or an unreadable result falls back to decoding the
    /// journal through `OfflineAudioRenderer` — the decode path the app already
    /// trusts for its own AAC on device — and encoding it at the storage format.
    /// One more lossy generation is a fair price for the only copy of the audio.
    static func exportToM4A(from source: URL, to destination: URL) async throws {
        do {
            try await passthroughExport(from: source, to: destination)
            if isReadable(destination) { return }
            AppLog.recorder.atError.error("capture journal rebuild: passthrough export is not decodable; re-encoding")
        } catch {
            AppLog.recorder.atError.error(
                "capture journal rebuild: passthrough export failed; re-encoding code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
        }
        try? FileManager.default.removeItem(at: destination)
        try await transcode(from: source, to: destination)
    }

    static func passthroughExport(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let preset = await AudioChunker.preferredPreset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.audioError(
                NSLocalizedString("error.export_session", comment: "Export session unavailable")
            )
        }
        try await session.export(to: destination, as: .m4a)
    }

    /// Decode `source` and encode it as the recording's own format. Its own
    /// function so the output `AVAudioFile` is released — and the container
    /// finalized — by the time it returns.
    static func transcode(from source: URL, to destination: URL) async throws {
        let failure = AppError.audioError(
            NSLocalizedString("error.export_session", comment: "Export session unavailable")
        )
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: AudioRecorderService.storageSampleRate) else {
            throw failure
        }
        let outFile = try CaptureOutputFile.open(at: destination, bitRate: AudioQuality.standard.bitRate)
        let renderer = OfflineAudioRenderer(outputFormat: outputFormat, failure: failure, logLabel: "capture journal rebuild")
        try await renderer.render(url: source) { buffer in
            try outFile.write(from: buffer)
        }
    }
}
