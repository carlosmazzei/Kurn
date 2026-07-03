//
//  TranscriptionRecovery.swift
//  Kurn
//
//  Cleans up recordings left stuck at `.inProgress` in the store with nobody
//  working on them — a process death mid-run, or a persist that couldn't land
//  (e.g. the app was relaunched in the background while the device was locked
//  and the protected store was unreadable, turning the launch sweep into a
//  silent no-op). Recordings whose run saved a checkpoint become `.pending` so
//  the foreground resume pass picks them up where they left off; runs that
//  never reached their first chunk have nothing to resume and are marked
//  `.failed` for a manual retry.
//
//  Runs at launch AND on every foreground activation: only the latter can fix
//  a store that was unreadable at launch, and `excluding` keeps it from
//  touching runs genuinely in flight in this process.
//

import Foundation
import SwiftData

enum TranscriptionRecovery {

    /// Reset every recording left `.inProgress` with nobody working on it.
    /// - Parameter activeIDs: recordings a live view model is actually
    ///   transcribing right now (empty at launch — a fresh process has no runs
    ///   yet). Works on the main context — the one the view models read — so
    ///   the corrected statuses are visible immediately rather than waiting
    ///   for a context refresh.
    @MainActor
    static func sweepStaleTranscriptions(
        modelContainer: ModelContainer,
        excluding activeIDs: Set<UUID> = []
    ) {
        let context = modelContainer.mainContext
        let inProgressRaw = TranscriptionStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.transcriptionStatusRaw == inProgressRaw }
        )
        guard let inProgress = try? context.fetch(descriptor) else { return }
        let stale = inProgress.filter { !activeIDs.contains($0.id) }
        guard !stale.isEmpty else { return }

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
