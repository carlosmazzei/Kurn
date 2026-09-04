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
import KurnCore
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
        // layout. Skipped fail-closed when the protected directory cannot be
        // established: legacy files stay put in Documents, still resolvable
        // via `AudioFileStore.resolveURL`.
        if let recordingsURL = try? AudioFileStore.ensureRecordingsDirectory() {
            RecordingProtection.migrateLegacyRecordings(
                documentsURL: AudioFileStore.documentsURL,
                recordingsURL: recordingsURL
            )
        }

        // Snapshot the activities synchronously, here at launch, BEFORE any
        // recording UI exists. Anything running now is by definition orphaned.
        // Ending happens asynchronously, so reading `.activities` inside the
        // Task instead could race a brand-new Live Activity started moments
        // after launch and tear it right back down. Only the launch-time
        // snapshot is touched.
        endOrphanedActivities()

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
        if let recordingsURL = try? AudioFileStore.ensureRecordingsDirectory() {
            RecordingProtection.migrateLegacyRecordings(
                documentsURL: AudioFileStore.documentsURL,
                recordingsURL: recordingsURL
            )
        }
        endOrphanedActivities()
        recoverOrphanedAudioFiles(context: modelContainer.mainContext)
    }

    @MainActor
    static func retryRecovery(for recording: Recording, context: ModelContext) -> AppError? {
        do {
            let metadata = try RecordingFileFinalizer().finalize(fileName: recording.fileName)
            recording.duration = metadata.duration
            recording.fileSize = metadata.fileSize
            recording.captureState = .ready
            recording.captureRecoveryReason = nil
            try context.save()
            CaptureReliability.finalized(fileName: recording.fileName, reason: nil, stage: "recovery")
            return nil
        } catch let error as RecordingFileFinalizationError {
            recording.captureState = .recoveryNeeded
            recording.captureRecoveryReason = error.recoveryReason
            CaptureReliability.finalized(fileName: recording.fileName, reason: error.recoveryReason, stage: "recovery")
            do {
                try context.save()
            } catch {
                return .persistenceFailed(error.localizedDescription)
            }
            return .audioError(NSLocalizedString(
                "recorder.recovery_failed",
                comment: "The recording could not be recovered"
            ))
        } catch {
            return .persistenceFailed(error.localizedDescription)
        }
    }

    /// Snapshot and asynchronously end every leftover Live Activity.
    /// Deliberately nonisolated: the snapshot is created inside this function,
    /// so it forms a disconnected region that can be sent into the ending task
    /// (capturing it from a `@MainActor` caller instead trips Swift 6's
    /// region-based data-race check on the non-Sendable activities).
    private static func endOrphanedActivities() {
        let orphaned = orphanedActivities()
        guard !orphaned.isEmpty else { return }
        Task {
            for activity in orphaned {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func recoverOrphanedAudioFiles(context: ModelContext) {
        guard let existing = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let known = Set(existing.map(\.fileName))

        // Rows created before `Recording.fileSize` existed carry 0. Backfilling
        // here rather than in a migration keeps it free: this sweep already runs
        // at launch and on every foreground activation.
        var changedAny = backfillFileSizes(in: existing)
        if reconcileInterruptedCaptures(in: existing) {
            changedAny = true
        }

        let items = (try? FileManager.default.contentsOfDirectory(
            at: AudioFileStore.recordingsDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in items where url.pathExtension.lowercased() == "m4a" {
            let fileName = url.lastPathComponent
            guard !known.contains(fileName) else { continue }
            if recover(fileName: fileName, at: url, context: context) {
                changedAny = true
            }
        }

        guard changedAny else { return }
        // `saveOrError()` already logs the failure (category "Persistence");
        // nothing here needs to react further, so it isn't logged a second
        // time, matching every other call site in the app.
        context.saveOrError()
    }

    private static func reconcileInterruptedCaptures(in recordings: [Recording]) -> Bool {
        let finalizer = RecordingFileFinalizer()
        var changed = false
        for recording in recordings where recording.captureState != .ready {
            let previousState = recording.captureState
            do {
                let metadata = try finalizer.finalize(fileName: recording.fileName)
                recording.duration = metadata.duration
                recording.fileSize = metadata.fileSize
                if previousState == .finalizing, recording.captureRecoveryReason == nil {
                    recording.captureState = .ready
                } else {
                    recording.captureState = .recoveryNeeded
                    if recording.captureRecoveryReason == nil {
                        switch previousState {
                        case .preparing:
                            recording.captureRecoveryReason = .interruptedBeforeStart
                        case .recording:
                            recording.captureRecoveryReason = .interruptedDuringCapture
                        case .finalizing:
                            recording.captureRecoveryReason = .interruptedDuringFinalization
                        case .ready, .recoveryNeeded:
                            break
                        }
                    }
                }
            } catch let error as RecordingFileFinalizationError {
                recording.captureState = .recoveryNeeded
                recording.captureRecoveryReason = error.recoveryReason
            } catch {
                recording.captureState = .recoveryNeeded
                recording.captureRecoveryReason = .unreadableFile
            }
            // Rows already in `.recoveryNeeded` are re-checked on every
            // activation; only a transition is worth a durable event.
            if previousState != .recoveryNeeded {
                CaptureReliability.finalized(
                    fileName: recording.fileName,
                    reason: recording.captureRecoveryReason,
                    stage: "reconcile"
                )
            }
            changed = true
        }
        return changed
    }

    /// Stat the backing file of every recording whose cached size is still
    /// unknown. Returns whether anything changed, so the caller only saves when
    /// there is something to save.
    private static func backfillFileSizes(in recordings: [Recording]) -> Bool {
        var changed = false
        for recording in recordings where recording.fileSize == 0 {
            let size = AudioFileStore.byteSize(fileName: recording.fileName)
            guard size > 0 else { continue }
            recording.fileSize = size
            changed = true
        }
        return changed
    }

    /// - Returns: whether `fileName` was reattached to a `Recording`. Files
    ///   that can't be placed — unparsable name, missing meeting, unreadable
    ///   container, negligible duration — are moved to `RecordingQuarantine`
    ///   rather than deleted: they are the only copy of the user's audio,
    ///   and Settings exposes recover/export/delete for each.
    private static func recover(fileName: String, at url: URL, context: ModelContext) -> Bool {
        guard let meetingID = meetingID(from: fileName) else {
            RecordingQuarantine.quarantine(fileAt: url, reason: .unparsableFileName)
            return false
        }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        descriptor.fetchLimit = 1
        guard let meeting = try? context.fetch(descriptor).first else {
            RecordingQuarantine.quarantine(fileAt: url, reason: .meetingNotFound)
            return false
        }
        let metadata: FinalizedRecordingFile
        do {
            metadata = try RecordingFileFinalizer().finalize(fileName: fileName)
        } catch {
            RecordingQuarantine.quarantine(fileAt: url, reason: .unreadableContainer)
            return false
        }
        guard metadata.duration >= 0.5 else {
            RecordingQuarantine.quarantine(fileAt: url, reason: .negligibleDuration)
            return false
        }
        let recording = Recording(
            meeting: meeting,
            fileName: fileName,
            duration: metadata.duration,
            fileSize: metadata.fileSize
        )
        context.insert(recording)
        AppLog.recorder.atNotice.notice(
            "recovery: reattached orphaned recording \(fileName, privacy: .public) duration=\(metadata.duration, privacy: .public)s"
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
