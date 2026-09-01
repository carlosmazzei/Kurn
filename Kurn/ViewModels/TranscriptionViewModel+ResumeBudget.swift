//
//  TranscriptionViewModel+ResumeBudget.swift
//  Kurn
//
//  H4 (PR 9): a checkpoint save must gate forward progress, and automatic
//  (unattended) resume attempts must be bounded so a systemic failure — a
//  chunk that always crashes, a full disk, a permanently-broken checkpoint —
//  can't retry forever, or for a cloud engine keep re-paying, every time the
//  app launches or foregrounds. Split out of TranscriptionViewModel.swift to
//  keep that file under SwiftLint's file-length limit, the same reason
//  TranscriptionViewModel+CrossMeetingSpeakerMatch.swift is a separate file.
//

import Foundation
import KurnCore
import SwiftData

extension TranscriptionViewModel {

    /// Persist chunk progress reported by the pipeline so an interruption at
    /// any point resumes from the last completed chunk. Throws (rather than
    /// merely logging, as the pre-H4 `storeCheckpoint` did) so a save
    /// failure gates forward progress: the pipeline awaits this before
    /// starting the next chunk, and a thrown error stops the run instead of
    /// continuing past a chunk that was never actually made durable.
    ///
    /// Also resets `automaticResumeAttempts` the first time this attempt
    /// saves a chunk beyond `completedChunksAtAttemptStart` — see
    /// `admitAutomaticResume`. Comparing against that fixed baseline, rather
    /// than whatever happens to be currently stored, is what makes a
    /// freshly-restarted run's own first chunk count as progress even when
    /// its `completedChunks` (1) is numerically lower than an abandoned
    /// prior run's — see `transcribe(_:language:config:)`. An attempt that
    /// never gets this far (crashes, is killed, or fails before completing
    /// even one further chunk) leaves the counter alone, which is exactly
    /// the "no forward progress" case that bound exists for.
    ///
    /// Not `private` — `transcribe(_:language:config:)` in the main file
    /// calls it.
    func storeCheckpointDurably(
        _ checkpoint: TranscriptionCheckpoint,
        for id: UUID,
        completedChunksAtAttemptStart: Int
    ) throws {
        guard let recording = activeRecordings[id] else { return }
        recording.transcriptionCheckpoint = checkpoint
        if checkpoint.completedChunks > completedChunksAtAttemptStart {
            recording.automaticResumeAttempts = 0
        }
        do {
            try modelContext.save()
        } catch {
            throw AppError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Consecutive automatic (unattended) resume attempts a recording may
    /// make with no forward progress before `admitAutomaticResume` refuses to
    /// start another one. Bounds the risk of a systemic failure — a chunk
    /// that always crashes, a full disk, a permanently-broken checkpoint —
    /// retrying forever, or for a cloud engine repeatedly re-paying, every
    /// time the app launches or foregrounds (H4).
    static let maxAutomaticResumeAttemptsWithoutProgress = 3

    /// Pure bound, exposed like `isResumableCancellation` so it's unit
    /// testable without a `Recording`/`ModelContext`: whether a recording
    /// that has already made `priorAttempts` automatic resume attempts with
    /// no forward progress may make one more.
    static func canAttemptAutomaticResume(afterPriorAttempts priorAttempts: Int) -> Bool {
        priorAttempts < maxAutomaticResumeAttemptsWithoutProgress
    }

    /// Gate for `resumePendingTranscriptions`: whether `recording` may be
    /// automatically resumed again. A row that already exhausted its budget
    /// is marked `.failed` instead (its checkpoint is kept, so a manual retry
    /// still resumes from the last completed chunk) — this is the "eventually
    /// requires user action" half of bounded recovery. Every admitted attempt
    /// counts against the budget up front, before the risky work runs, so a
    /// crash mid-attempt is still counted against it on the next launch.
    private func admitAutomaticResume(_ recording: Recording) -> Bool {
        guard Self.canAttemptAutomaticResume(afterPriorAttempts: recording.automaticResumeAttempts) else {
            AppLog.transcription.atError.error(
                "VM: automatic resume budget exhausted id=\(recording.id, privacy: .public) attempts=\(recording.automaticResumeAttempts, privacy: .public), requires manual retry"
            )
            recording.transcriptionStatus = .failed
            persist()
            return false
        }
        recording.automaticResumeAttempts += 1
        persist()
        return true
    }

    /// An explicit user retry always gets a fresh automatic-resume budget,
    /// regardless of how many unattended attempts already failed — a
    /// deliberate action is exactly the "user action" `admitAutomaticResume`
    /// is waiting for. Called from every manual start/retry/retranscribe
    /// entry point, never from `resumePendingTranscriptions` itself.
    func resetAutomaticResumeBudget(for recording: Recording) {
        recording.automaticResumeAttempts = 0
    }

    /// Start every recording left `.pending` — interrupted mid-transcription
    /// with its progress checkpointed. Called when the app becomes active;
    /// safe to call repeatedly (in-flight recordings are skipped by the
    /// re-entrancy guards).
    func resumePendingTranscriptions(settings: AppSettings) {
        let pendingRaw = TranscriptionStatus.pending.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.transcriptionStatusRaw == pendingRaw }
        )
        guard let pending = try? modelContext.fetch(descriptor), !pending.isEmpty else { return }
        AppLog.transcription.atNotice.notice("VM: resuming \(pending.count, privacy: .public) pending transcription(s)")
        for recording in pending {
            guard admitAutomaticResume(recording) else { continue }
            startTranscription(
                recording,
                language: recording.meeting?.language ?? .autoDetect,
                config: settings.pipelineConfiguration
            )
        }
    }
}
