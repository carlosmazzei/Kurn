//
//  RecordingRecovery.swift
//  Kurn
//
//  Runs once at launch to clean up after a process that died mid-recording
//  (e.g. the OS reclaiming memory during a long background recording). Two
//  things can be left behind: a Live Activity nobody will ever end, and an
//  audio file on disk with no matching `Recording` row because the process
//  never reached `stopAndSave()`.
//

import ActivityKit
import AVFoundation
import Foundation
import SwiftData

enum RecordingRecovery {
    /// Snapshot of any Live Activities left over from a previous process.
    /// This must be captured synchronously at launch, BEFORE any recording UI
    /// exists, so a brand-new Live Activity started moments after launch is
    /// not mistaken for an orphan. Ending activities happens asynchronously,
    /// so reading `.activities` inside a background Task could race a new
    /// recording and tear it right back down.
    static func orphanedActivities() -> [Activity<RecordingActivityAttributes>] {
        Activity<RecordingActivityAttributes>.activities
    }

    /// Ends any Live Activity left over from a previous process and reattaches
    /// any orphaned audio file to its meeting. Safe to call unconditionally at
    /// launch: a fresh process never has a live recording session yet, so any
    /// `RecordingActivityAttributes` activity still running is by definition
    /// orphaned.
    static func recoverOrphans(modelContainer: ModelContainer) {
        // Migrate any legacy `.m4a` left in Documents into the protected
        // recordings directory before scanning for orphans, so the scan and
        // every subsequent file access happens against the post-migration
        // layout.
        RecordingProtection.migrateLegacyRecordings(
            documentsURL: AudioFileStore.documentsURL,
            recordingsURL: AudioFileStore.recordingsDirectoryURL
        )

        // Snapshot the activities synchronously, here at launch, BEFORE any
        // recording UI exists. Anything running now is by definition orphaned.
        // Ending happens asynchronously, so reading `.activities` inside the
        // Task instead could race a brand-new Live Activity started moments
        // after launch and tear it right back down. Only the launch-time
        // snapshot is touched.
        let orphaned = orphanedActivities()
        if !orphaned.isEmpty {
            Task {
                for activity in orphaned {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }

        recoverOrphanedAudioFiles(context: ModelContext(modelContainer))
    }

    /// Foreground-activation variant of `recoverOrphans`: reattaches orphaned
    /// audio (and ends stuck Live Activities) without waiting for the next
    /// cold launch — a recording abandoned by an unexpected UI teardown would
    /// otherwise sit invisible on disk until the user happens to relaunch.
    /// Skipped entirely while a recorder session is live: its in-progress file
    /// has no `Recording` row yet and must never be treated as an orphan, and
    /// its Live Activity is not stuck. Works on the main context so a
    /// reattached recording appears in the UI immediately.
    @MainActor
    static func recoverOrphansOnActivate(modelContainer: ModelContainer) {
        guard !RecordingCommandRouter.shared.hasActiveSession else { return }
        // Same pre-scan migration as the launch path (idempotent and cheap),
        // so the orphan scan below always sees the post-migration layout.
        RecordingProtection.migrateLegacyRecordings(
            documentsURL: AudioFileStore.documentsURL,
            recordingsURL: AudioFileStore.recordingsDirectoryURL
        )
        let orphaned = orphanedActivities()
        if !orphaned.isEmpty {
            Task {
                for activity in orphaned {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        recoverOrphanedAudioFiles(context: modelContainer.mainContext)
    }

    private static func recoverOrphanedAudioFiles(context: ModelContext) {
        guard let knownFileNames = try? context.fetch(FetchDescriptor<Recording>()).map(\.fileName) else {
            return
        }
        let known = Set(knownFileNames)

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: AudioFileStore.recordingsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        var recoveredAny = false
        for url in items where url.pathExtension.lowercased() == "m4a" {
            let fileName = url.lastPathComponent
            guard !known.contains(fileName) else { continue }
            if recover(fileName: fileName, at: url, context: context) {
                recoveredAny = true
            }
        }

        guard recoveredAny else { return }
        do {
            try context.save()
        } catch {
            AppLog.recorder.atError.error("recovery: failed to save recovered recordings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unreadable orphans at or above this size are kept on disk instead of
    /// deleted: a large `.m4a` whose container was never finalized (the writer
    /// was torn down without `stop()`) fails to open here, but it is the only
    /// copy of the user's audio — deleting it destroys a potentially long
    /// meeting with no recourse, while keeping it costs a little disk and
    /// leaves repair/manual extraction possible.
    static let keepUnreadableMinBytes = 1_000_000

    /// - Returns: whether `fileName` was reattached to a `Recording`. Files that
    ///   can't be matched to a meeting never get a second chance, so they're
    ///   deleted instead of lingering in Documents forever; unreadable files
    ///   are only deleted when they're too small to plausibly matter.
    private static func recover(fileName: String, at url: URL, context: ModelContext) -> Bool {
        guard let meetingID = meetingID(from: fileName) else {
            AudioFileStore.delete(fileName: fileName)
            return false
        }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        descriptor.fetchLimit = 1
        guard let meeting = try? context.fetch(descriptor).first else {
            AudioFileStore.delete(fileName: fileName)
            return false
        }
        let duration = readableDuration(of: url)
        guard let duration, duration >= 0.5 else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if duration == nil, size >= Self.keepUnreadableMinBytes {
                AppLog.recorder.atError.error(
                    "recovery: keeping unreadable orphan \(fileName, privacy: .public) (\(size, privacy: .public) bytes) — container not finalized"
                )
                return false
            }
            AudioFileStore.delete(fileName: fileName)
            return false
        }
        let recording = Recording(meeting: meeting, fileName: fileName, duration: duration)
        context.insert(recording)
        AppLog.recorder.atNotice.notice(
            "recovery: reattached orphaned recording \(fileName, privacy: .public) duration=\(duration, privacy: .public)s"
        )
        return true
    }

    /// Parses the `{meetingID}_{timestamp}.m4a` convention from `AudioFileStore.fileName`.
    private static func meetingID(from fileName: String) -> UUID? {
        guard let underscoreIndex = fileName.firstIndex(of: "_") else { return nil }
        return UUID(uuidString: String(fileName[..<underscoreIndex]))
    }

    /// A file abandoned mid-write by `AVAudioFile` may still have a readable
    /// sample table; if not, this returns nil and the caller discards it.
    private static func readableDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return nil
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite ? duration : nil
    }
}
