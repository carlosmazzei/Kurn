//
//  TranscriptionRecovery.swift
//  Kurn
//
//  Runs once at launch to clean up after a process that died mid-transcription
//  (the OS suspending and then killing the app during a long chunked run).
//  Such a recording is left stuck at `.inProgress` in the store with nobody
//  working on it. Recordings whose run saved a checkpoint become `.pending` so
//  the foreground resume pass picks them up where they left off; runs that
//  never reached their first chunk have nothing to resume and are marked
//  `.failed` for a manual retry.
//

import Foundation
import SwiftData

enum TranscriptionRecovery {

    /// Reset every recording left `.inProgress` by a dead process. Safe to call
    /// unconditionally at launch: a fresh process has no transcription running
    /// yet, so any `.inProgress` row is by definition stale. Works on the main
    /// context — the one the view models read — so the corrected statuses are
    /// visible immediately rather than waiting for a context refresh.
    @MainActor
    static func sweepStaleTranscriptions(modelContainer: ModelContainer) {
        let context = modelContainer.mainContext
        let inProgressRaw = TranscriptionStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.transcriptionStatusRaw == inProgressRaw }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }

        var resumable = 0
        for recording in stale {
            if recording.transcriptionCheckpointData != nil {
                recording.transcriptionStatus = .pending
                resumable += 1
            } else {
                recording.transcriptionStatus = .failed
            }
        }
        do {
            try context.save()
            AppLog.transcription.atNotice.notice("recovery: swept \(stale.count, privacy: .public) stale transcription(s), \(resumable, privacy: .public) resumable")
        } catch {
            AppLog.transcription.atError.error("recovery: sweep save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
