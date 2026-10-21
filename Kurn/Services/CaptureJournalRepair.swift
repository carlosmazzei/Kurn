//
//  CaptureJournalRepair.swift
//  Kurn
//
//  Rebuilds a recording's `.m4a` from its `CaptureJournal` when the process
//  that was capturing it died before closing the file. The rebuild is a remux
//  (passthrough export of the ADTS frames into an MPEG-4 container), so the
//  audio is the same encoded bytes the recording would have held — there is no
//  second lossy generation, unless the system reports passthrough unavailable
//  for the asset, in which case `AudioChunker.preferredPreset` re-encodes.
//
//  The rebuild is written to a temporary file and verified decodable before it
//  replaces anything, and it never replaces a recording that is already
//  readable: a cleanly closed `.m4a` is the authoritative copy, and its journal
//  is simply discarded by `RecordingFileFinalizer`. The journal itself is kept
//  until that finalizer accepts the rebuilt file.
//

import AVFoundation
import Foundation

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

    /// Remux the ADTS journal into an `.m4a`.
    static func exportToM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let preset = await AudioChunker.preferredPreset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.audioError(
                NSLocalizedString("error.export_session", comment: "Export session unavailable")
            )
        }
        try await session.export(to: destination, as: .m4a)
    }
}
