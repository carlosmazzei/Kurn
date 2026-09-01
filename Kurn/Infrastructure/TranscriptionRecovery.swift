//
//  TranscriptionRecovery.swift
//  Kurn
//
//  Cleans up recordings left stuck at `.inProgress` in the store with nobody
//  working on them — a process death mid-run, or a persist that couldn't land
//  (e.g. the app was relaunched in the background while the device was locked
//  and the protected store was unreadable, turning the launch sweep into a
//  silent no-op). All stale recordings are reset to `.pending` so the
//  foreground resume pass retries them; those with a checkpoint resume from
//  where they left off, those without start from the beginning. The audio
//  file is always intact, so every case is retryable — marking no-checkpoint
//  runs as `.failed` prevented Whisper uploads killed mid-flight (background
//  task expiry, process death at ~94% upload) from ever retrying.
//
//  Runs at launch AND on every foreground activation: only the latter can fix
//  a store that was unreadable at launch, and `excluding` keeps it from
//  touching runs genuinely in flight in this process.
//

import Foundation
import KurnCore
import SwiftData

enum TranscriptionRecovery {

    /// Reset every recording left `.inProgress` with nobody working on it.
    /// Only a checkpoint from a known on-device engine resumes automatically;
    /// cloud or unknown work may have completed remotely and requires manual retry.
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
        let readyRaw = RecordingCaptureState.ready.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.transcriptionStatusRaw == inProgressRaw && $0.captureStateRaw == readyRaw
            }
        )
        guard let inProgress = try? context.fetch(descriptor) else { return }
        let stale = inProgress.filter { !activeIDs.contains($0.id) }
        guard !stale.isEmpty else { return }

        var resumable = 0
        for recording in stale {
            let outcome = recording.transcriptionCheckpointOutcome
            if outcome.isCorrupted {
                // A checkpoint that fails to decode or verify cannot say what
                // engine produced it, so it gets the same treatment as cloud
                // or unknown work: manual retry, never an automatic resume
                // spliced from unverifiable progress.
                AppLog.transcription.atError.error(
                    "recovery: corrupted checkpoint id=\(recording.id, privacy: .public), requires manual retry"
                )
                recording.transcriptionStatus = .failed
            } else if let checkpoint = outcome.decodedValue,
                      checkpoint.engineRaw != TranscriptionEngine.whisperAPI.rawValue {
                // A checkpoint that decoded and verified but fails its own
                // structural sanity check (H4) is just as unsafe to resume
                // from as a corrupted one — it just happens to still parse.
                if checkpoint.isStructurallyValid {
                    recording.transcriptionStatus = .pending
                    resumable += 1
                } else {
                    AppLog.transcription.atError.error(
                        "recovery: structurally invalid checkpoint id=\(recording.id, privacy: .public), requires manual retry"
                    )
                    recording.transcriptionStatus = .failed
                }
            } else {
                recording.transcriptionStatus = .failed
            }
        }
        do {
            try context.save()
            AppLog.transcription.atNotice.notice("recovery: swept \(stale.count, privacy: .public) stale transcription(s), \(resumable, privacy: .public) safe to resume")
        } catch {
            AppLog.transcription.atError.error("recovery: sweep save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
