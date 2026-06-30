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
        let orphaned = Activity<RecordingActivityAttributes>.activities
        if !orphaned.isEmpty {
            Task {
                for activity in orphaned {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        recoverOrphanedAudioFiles(modelContainer: modelContainer)
    }

    private static func recoverOrphanedAudioFiles(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
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

    /// - Returns: whether `fileName` was reattached to a `Recording`. Files that
    ///   can't be matched to a meeting or read back never get a second chance,
    ///   so they're deleted instead of lingering in Documents forever.
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
        guard let duration = readableDuration(of: url), duration >= 0.5 else {
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
