//
//  CaptureJournal.swift
//  Kurn
//
//  A crash-safe second copy of the recording being captured. The stored
//  `.m4a` is an MPEG-4 container: its sample table (the `moov` atom) is only
//  written when `AVAudioFile` closes, so a process killed mid-recording — the
//  user swiping the app away, a jetsam kill — leaves a file full of audio that
//  nothing can decode, because raw AAC frames carry no framing of their own.
//
//  So every buffer the sink writes to the `.m4a` is also written to an ADTS
//  stream (`.aac`): each AAC frame there carries its own header, and there is
//  no trailer, so a file cut off at any byte is decodable up to its last whole
//  frame. On a clean stop the `.m4a` is complete and `RecordingFileFinalizer`
//  discards the journal; after a kill, `CaptureJournalRepair` rebuilds the
//  `.m4a` from it.
//
//  Journals live in `Recordings/Capture/` under the recording's own base name
//  with an `.aac` extension. The nested directory keeps them out of every
//  shallow `.m4a` sweep, for the same reason as
//  `RecordingProtection.enhancedDirectoryName`.
//

import AVFoundation
import Foundation
import KurnCore

enum CaptureJournal {
    static let fileExtension = "aac"

    /// The journal roughly doubles the bytes a recording writes while it is
    /// running (same bit rate, a few bytes of ADTS header per frame), which the
    /// storage runway has to account for.
    static let storageMultiplier = 2

    /// **Computed only — this does not create or re-stamp anything.**
    static var directoryURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.captureJournalDirectoryName, isDirectory: true)
    }

    /// Same directory, created and protection-stamped, for the writer.
    @discardableResult
    static func ensureDirectory(fileManager: FileManager = .default) throws -> URL {
        let parent = try AudioFileStore.ensureRecordingsDirectory(fileManager: fileManager)
        do {
            return try RecordingProtection.ensureProtectedDirectory(
                named: RecordingProtection.captureJournalDirectoryName,
                in: parent,
                fileManager: fileManager
            )
        } catch {
            throw AppError.protectedStorageUnavailable(error.localizedDescription)
        }
    }

    /// `X.m4a` → `X.aac`.
    static func journalFileName(for recordingFileName: String) -> String {
        let base = (recordingFileName as NSString).deletingPathExtension
        return "\(base).\(fileExtension)"
    }

    /// `X.aac` → `X.m4a`, the recording a journal belongs to.
    static func recordingFileName(forJournal journalFileName: String) -> String {
        let base = (journalFileName as NSString).deletingPathExtension
        return "\(base).m4a"
    }

    static func url(for recordingFileName: String) -> URL {
        directoryURL.appendingPathComponent(journalFileName(for: recordingFileName))
    }

    static func exists(for recordingFileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: recordingFileName).path)
    }

    static func delete(for recordingFileName: String) {
        try? FileManager.default.removeItem(at: url(for: recordingFileName))
    }

    /// The recording file names that currently have a journal on disk.
    static func recordingFileNamesWithJournal() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .map { recordingFileName(forJournal: $0.lastPathComponent) }
    }

    /// Remove every journal (used by "Delete All Data"). Returns how many
    /// could not be removed.
    @discardableResult
    static func deleteAll(fileManager: FileManager = .default) -> Int {
        let items = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        var residual = 0
        for url in items where url.pathExtension.lowercased() == fileExtension {
            try? fileManager.removeItem(at: url)
            if fileManager.fileExists(atPath: url.path) { residual += 1 }
        }
        return residual
    }

    /// Encoder settings for the journal: the recording's own settings, written
    /// as an ADTS stream instead of an MPEG-4 container.
    static func settings(bitRate: Int?) -> [String: Any] {
        var settings = CaptureOutputFile.settings(bitRate: bitRate)
        settings[AVAudioFileTypeKey] = Int(kAudioFileAAC_ADTSType)
        return settings
    }
}

/// The file the sink writes to while a journal is attached: every buffer goes
/// to the recording and to the journal.
///
/// The journal is a safety net, never a reason to lose the recording: a
/// journal write failure detaches the journal (and is reported once) while the
/// recording carries on, and only the recording's own failure is thrown to
/// the sink. Called on the render thread under the sink's lock, like any
/// `AudioFileWriting`.
final class JournaledCaptureFile: AudioFileWriting {
    private let primary: any AudioFileWriting
    private var journal: (any AudioFileWriting)?
    private let onJournalFailure: () -> Void

    init(
        primary: any AudioFileWriting,
        journal: any AudioFileWriting,
        onJournalFailure: @escaping () -> Void = {}
    ) {
        self.primary = primary
        self.journal = journal
        self.onJournalFailure = onJournalFailure
    }

    var hasJournal: Bool { journal != nil }

    func write(from buffer: AVAudioPCMBuffer) throws {
        // The journal is written first so a buffer the recording rejects is
        // still preserved in the copy that survives a kill.
        if let journal {
            do {
                try journal.write(from: buffer)
            } catch {
                self.journal = nil
                onJournalFailure()
            }
        }
        try primary.write(from: buffer)
    }
}

extension CaptureOutputFile {
    /// Open the recording at `url` plus its crash-safe journal. A journal that
    /// cannot be opened leaves the recording unjournaled (logged) rather than
    /// failing the start: it protects the recording, it is not the recording.
    static func openJournaled(
        at url: URL,
        bitRate: Int,
        make: (URL, [String: Any]) throws -> any AudioFileWriting = { try AVAudioFile(forWriting: $0, settings: $1) },
        journalDirectory: () throws -> URL = { try CaptureJournal.ensureDirectory() }
    ) throws -> any AudioFileWriting {
        let primary = try open(at: url, bitRate: bitRate, make: make)
        let fileName = url.lastPathComponent
        let journal: any AudioFileWriting
        do {
            let journalURL = try journalDirectory()
                .appendingPathComponent(CaptureJournal.journalFileName(for: fileName))
            do {
                journal = try make(journalURL, CaptureJournal.settings(bitRate: bitRate))
            } catch {
                journal = try make(journalURL, CaptureJournal.settings(bitRate: nil))
            }
        } catch {
            AppLog.recorder.atError.error(
                "capture journal could not be opened; recording without it code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            return primary
        }
        return JournaledCaptureFile(primary: primary, journal: journal) {
            AppLog.recorder.atError.error("capture journal write failed; detached for the rest of this recording file=\(fileName, privacy: .public)")
        }
    }
}
