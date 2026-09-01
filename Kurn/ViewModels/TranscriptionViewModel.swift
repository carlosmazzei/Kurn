//
//  TranscriptionViewModel.swift
//  Kurn
//
//  Coordinates transcription and summary generation for a meeting and writes the
//  results back into SwiftData. Heavy work runs in the value-type services off
//  the main actor; all model mutation happens here on the main actor.
//

import Foundation
import KurnCore
import Observation
import SwiftData
import SwiftUI // for Color.speakerHex palette helper

@MainActor
@Observable
final class TranscriptionViewModel {
    /// An ordered update emitted by the transcription pipeline's `@Sendable`
    /// callbacks and applied on the main actor in emission order (see
    /// `transcribe(_:language:config:)`). Checkpoints are deliberately not
    /// routed through this channel (see `onCheckpoint` below, H4): a
    /// checkpoint must be durably saved — and its save failure must stop the
    /// pipeline — before the next chunk starts, which a fire-and-forget
    /// `continuation.yield` cannot do.
    private enum PipelineEvent: Sendable {
        case phase(TranscriptionPhase)
        case diarizationWarning(String)
    }

    /// IDs of recordings currently transcribing, for per-row spinners.
    private(set) var transcribingIDs: Set<UUID> = []
    /// Active pipeline phase per recording, so the UI can show the current stage.
    private(set) var phases: [UUID: TranscriptionPhase] = [:]
    /// Best-effort work still running after a transcript has already been saved.
    /// Kept separate from `phases` so the recording can honestly show `.done`
    /// instead of holding the transcription bar at "Finalizing".
    private(set) var postTranscriptionPhases: [UUID: PostTranscriptionPhase] = [:]
    /// Not `private(set)` — `TranscriptionViewModel+Summary.swift` needs to
    /// set these from its own file.
    var isSummarizing = false
    /// True after the user asks to cancel a summary while the provider request
    /// is still unwinding.
    var isCancellingSummary = false
    /// Staged-summary progress as (stage, total) when a long transcript is
    /// being summarized in parts; nil for single-pass summaries.
    var summaryProgress: (stage: Int, total: Int)?
    var error: AppError?
    /// Non-fatal diarization failures (e.g. a FluidAudio model download error),
    /// keyed by recording so concurrent transcriptions of different recordings
    /// never clobber or misattribute each other's warning. Transcription still
    /// succeeds; this is a banner, not an `AppError`.
    private(set) var diarizationWarnings: [UUID: String] = [:]
    /// A voiceprint match for a new `Speaker` row, found in a different
    /// meeting — staged, never silently applied. See
    /// `TranscriptionViewModel+CrossMeetingSpeakerMatch.swift`.
    var pendingCrossMeetingMatches: [CrossMeetingSpeakerMatch] = []

    /// Task handles for transcriptions started via `startTranscription`, so
    /// they can be cancelled (by the user or by the background window expiring).
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Post-transcription work is intentionally unstructured relative to the
    /// transcription task: pausing/stopping the audio pipeline no longer applies
    /// after its transcript has been persisted.
    private var postTranscriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Identity guard preventing a cancelled task's deferred cleanup from
    /// clearing a newer task registered for the same recording.
    private var postTranscriptionRunIDs: [UUID: UUID] = [:]
    /// Meeting associated with each post-processing task. Starting another
    /// transcription for the same meeting cancels stale work based on the old
    /// transcript, even when it belongs to a different recording.
    private var postTranscriptionMeetingIDs: [UUID: UUID] = [:]
    /// Recordings being fully stopped (not just paused): on cancellation their
    /// checkpoint is cleared and status resets to `.none` instead of `.pending`.
    private var stoppingIDs: Set<UUID> = []
    /// Recordings for which a cancel/stop was requested but the cooperative task
    /// cancellation hasn't propagated yet. The UI uses this for immediate feedback.
    private(set) var cancellingIDs: Set<UUID> = []
    /// Recordings this instance is transcribing, so `@Sendable` pipeline
    /// callbacks can reach the model by ID after hopping to the main actor.
    /// Not `private` — `TranscriptionViewModel+ResumeBudget.swift` needs it.
    var activeRecordings: [UUID: Recording] = [:]
    /// Active summary task, owned here so the detail screen can cancel it.
    /// Not `private` — `TranscriptionViewModel+Summary.swift` needs it.
    var summaryTask: Task<Void, Never>?
    /// Recordings in flight across ALL instances — `MeetingDetailView` creates
    /// a view model per screen and the app-level resume coordinator has its
    /// own, and a recording must never transcribe twice concurrently.
    private static var globalActiveIDs: Set<UUID> = []

    /// Recordings some view model in this process is actually working on.
    /// The foreground recovery sweep uses this to distinguish a live run
    /// (leave alone) from a stale persisted `.inProgress` (reset to resumable).
    static var activeTranscriptionIDs: Set<UUID> { globalActiveIDs }

    /// Not `private` — `TranscriptionViewModel+CrossMeetingSpeakerMatch.swift` needs it.
    let modelContext: ModelContext
    private let transcriptionService = TranscriptionService()
    /// Not `private` — `TranscriptionViewModel+Summary.swift` needs it.
    let summaryService = SummaryService()
    private let aiTitleCoordinator: AITitleCoordinator
    /// App-wide settings, set by `KurnApp` so title generation can use the
    /// configured LLM provider without passing settings through every call site.
    var appSettings: AppSettings?
    /// App-wide semantic-index coordinator, set by `KurnApp`. A finished
    /// transcription updates the meeting's on-device index through it.
    var semanticIndexCoordinator: SemanticIndexCoordinator?
    /// App-wide wiki coordinator, set by `KurnApp`. A finished transcription
    /// refreshes the meeting's condensed wiki article through it (opt-in).
    var wikiCoordinator: WikiCoordinator?

    init(
        modelContext: ModelContext,
        aiTitleCoordinator: AITitleCoordinator = AITitleCoordinator()
    ) {
        self.modelContext = modelContext
        self.aiTitleCoordinator = aiTitleCoordinator
    }

    /// Persist pending model changes, surfacing failures instead of dropping
    /// them silently — a failed save otherwise leaves the in-memory models and
    /// the store diverged (e.g. status shown as `.done` but stored as `.inProgress`).
    func persist() {
        do {
            try modelContext.save()
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
        }
    }

    func isTranscribing(_ recording: Recording) -> Bool {
        transcribingIDs.contains(recording.id)
    }

    func isCancelling(_ recording: Recording) -> Bool {
        cancellingIDs.contains(recording.id)
    }

    /// The pipeline stage currently running for a recording, if any.
    func phase(for recording: Recording) -> TranscriptionPhase? {
        phases[recording.id]
    }

    func postTranscriptionPhase(for recording: Recording) -> PostTranscriptionPhase? {
        postTranscriptionPhases[recording.id]
    }

    // MARK: - Transcription

    /// Request the on-device Speech permission. Only the Apple Speech engine
    /// needs it; the FluidAudio and Whisper engines don't use `SFSpeechRecognizer`.
    func ensureSpeechAuthorization() async -> Bool {
        await OnDeviceTranscriber().requestAuthorization()
    }

    /// Start (or resume) a transcription as a cancellable task owned by this
    /// view model. Prefer this over calling `transcribe` directly: it keeps a
    /// task handle so the run can be paused when the background window expires
    /// or the user cancels.
    func startTranscription(
        _ recording: Recording,
        language: MeetingLanguage,
        config: PipelineConfiguration
    ) {
        guard recording.isReadyForConsumption else { return }
        let recordingID = recording.id
        guard transcriptionTasks[recordingID] == nil,
              !Self.globalActiveIDs.contains(recordingID) else {
            AppLog.transcription.atInfo.info("VM: start ignored, already in flight id=\(recordingID, privacy: .public)")
            return
        }
        transcriptionTasks[recordingID] = Task { [weak self] in
            await self?.transcribe(recording, language: language, config: config)
            self?.transcriptionTasks[recordingID] = nil
        }
    }

    /// Cancel an in-flight transcription started via `startTranscription`.
    /// Progress up to the last completed chunk stays in the checkpoint and the
    /// recording is left `.pending`, so a later run resumes rather than restarts.
    func cancelTranscription(_ recording: Recording) {
        let recordingID = recording.id
        AppLog.transcription.atNotice.notice("VM: pause requested id=\(recordingID, privacy: .public) phase=\(self.phases[recordingID]?.displayName ?? "unknown", privacy: .public) taskFound=\(self.transcriptionTasks[recordingID] != nil, privacy: .public)")
        cancellingIDs.insert(recording.id)
        transcriptionTasks[recording.id]?.cancel()
    }

    /// Fully stop an in-flight transcription: cancels the task, clears any saved
    /// checkpoint, and resets status to `.none` so the user must start fresh.
    func stopTranscription(_ recording: Recording) {
        let recordingID = recording.id
        AppLog.transcription.atNotice.notice("VM: stop requested id=\(recordingID, privacy: .public) phase=\(self.phases[recordingID]?.displayName ?? "unknown", privacy: .public) taskFound=\(self.transcriptionTasks[recordingID] != nil, privacy: .public)")
        cancellingIDs.insert(recording.id)
        stoppingIDs.insert(recording.id)
        transcriptionTasks[recording.id]?.cancel()
    }

    /// Cancel every in-flight transcription started via `startTranscription`.
    /// Used when a `BGProcessingTask` window expires: each run checkpoints and
    /// parks as `.pending` for the next resume pass.
    func cancelAllTranscriptions() {
        for task in transcriptionTasks.values {
            task.cancel()
        }
    }

    /// Wait until every transcription task started via `startTranscription`
    /// has finished (each removes itself from the registry as it completes).
    func awaitActiveTranscriptions() async {
        while let entry = transcriptionTasks.first {
            await entry.value.value
            transcriptionTasks[entry.key] = nil
        }
    }

    func transcribe(
        _ recording: Recording,
        language: MeetingLanguage,
        config: PipelineConfiguration
    ) async {
        guard recording.isReadyForConsumption,
              !transcribingIDs.contains(recording.id),
              !Self.globalActiveIDs.contains(recording.id) else { return }

        let recordingID = recording.id
        AppLog.transcription.atNotice.notice("VM: transcribe requested id=\(recordingID, privacy: .public) engine=\(config.transcription.rawValue, privacy: .public)")

        cancelPostTranscriptionWork(for: recording.meeting?.id)
        transcribingIDs.insert(recordingID)
        Self.globalActiveIDs.insert(recordingID)
        activeRecordings[recordingID] = recording
        phases[recordingID] = .preparing
        defer {
            transcribingIDs.remove(recordingID)
            Self.globalActiveIDs.remove(recordingID)
            activeRecordings[recordingID] = nil
            phases[recordingID] = nil
            cancellingIDs.remove(recordingID)
        }
        recording.transcriptionStatus = .inProgress
        recording.transcriptionMode = config.transcription.storageMode
        persist()

        // Only the Apple Speech engine uses `SFSpeechRecognizer`; the FluidAudio
        // and Whisper engines don't, so don't gate them on (or block them by a
        // denial of) the Speech authorization.
        let usesAppleSpeech = config.transcription == .appleSpeech
        if usesAppleSpeech {
            let authorized = await ensureSpeechAuthorization()
            guard authorized else {
                AppLog.transcription.atError.error("VM: speech permission denied")
                recording.transcriptionStatus = .failed
                persist()
                error = .permissionDenied(
                    NSLocalizedString("error.speech_permission", comment: "Speech permission")
                )
                return
            }
        }

        // Capture primitives before suspending.
        let fileURL = recording.fileURL
        let fileName = recording.fileName
        diarizationWarnings[recordingID] = nil

        // Progress persisted by an earlier interrupted run; the pipeline skips
        // already-transcribed chunks when it still matches. A checkpoint that
        // fails to decode or verify starts this run from the beginning, but
        // the discard is explicit and logged, never a lenient decode's nil.
        let checkpointOutcome = recording.transcriptionCheckpointOutcome
        if checkpointOutcome.isCorrupted {
            AppLog.transcription.atError.error("VM: checkpoint corrupted id=\(recordingID, privacy: .public), starting over")
        }
        let checkpoint = checkpointOutcome.decodedValue
        if let checkpoint {
            AppLog.transcription.atNotice.notice("VM: checkpoint found id=\(recordingID, privacy: .public) engine=\(checkpoint.engineRaw, privacy: .public) lang=\(checkpoint.languageRaw, privacy: .public) compacted=\(checkpoint.compacted, privacy: .public) chunks=\(checkpoint.completedChunks, privacy: .public)/\(checkpoint.totalChunks, privacy: .public) spans=\(checkpoint.spans.count, privacy: .public)")
        }
        // Baseline for the automatic-resume budget (H4): captured once, before
        // this attempt does anything, so "did this attempt make progress" is
        // judged against where it *started* — not against whatever happens to
        // be currently stored. That distinction matters when the pipeline
        // configuration changed since the last attempt: a mismatched
        // fingerprint restarts the chunk plan from zero, so the freshly
        // restarted run's own first saved chunk must still count as progress
        // even though its `completedChunks` (1) is lower than the abandoned
        // old run's (which could be much higher).
        let completedChunksAtAttemptStart = checkpoint?.completedChunks ?? 0

        // Long transcriptions (especially the chunked Whisper path) would
        // otherwise be aborted when the app is backgrounded and the system
        // suspends it. Hold a background-task assertion for the duration so the
        // work gets a finite grace window; when the system reclaims it, cancel
        // the run so it checkpoints as `.pending` (resumed on next foreground)
        // instead of freezing mid-chunk.
        let background = BackgroundActivity()
        background.begin(name: "ai.kurn.transcription") { [weak self] in
            AppLog.transcription.atNotice.notice("VM: background task expired, cancelling id=\(recordingID, privacy: .public)")
            self?.transcriptionTasks[recordingID]?.cancel()
        }
        defer { background.end() }

        // Phase/warning callbacks fire off the main actor. Route them through a
        // single ordered channel (rather than spawning an independent
        // `Task { @MainActor }` per callback, which has no ordering guarantee)
        // so they apply in emission order and are fully drained before the
        // completion/error path mutates the recording. Checkpoints skip this
        // channel entirely (see `onCheckpoint` below): they are awaited and
        // saved synchronously inline with the pipeline, so by the time
        // `transcribe` returns every checkpoint save has already completed —
        // there is no "enqueued but not yet applied" checkpoint state left to
        // race against `saveTranscript`/the stop path clearing it.
        let (events, continuation) = AsyncStream<PipelineEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { continue }
                switch event {
                case .phase(let phase): self.phases[recordingID] = phase
                case .diarizationWarning(let message): self.diarizationWarnings[recordingID] = message
                }
            }
        }
        // `finish()` is idempotent; the explicit `drainEvents()` calls close the
        // stream first, this is only a safety net for any future exit path.
        defer { continuation.finish() }

        // Close the channel and wait for the consumer to apply every pending
        // event before touching completion/error state. Call this first in the
        // success path and in every `catch`, ahead of any recording mutation.
        func drainEvents() async {
            continuation.finish()
            await consumer.value
        }

        do {
            let output = try await transcriptionService.transcribe(
                fileURL: fileURL,
                fileName: fileName,
                language: language,
                config: config,
                checkpoint: checkpoint,
                onPhase: { continuation.yield(.phase($0)) },
                onDiarizationWarning: { continuation.yield(.diarizationWarning($0)) },
                onCheckpoint: { [weak self] checkpoint in
                    try await self?.storeCheckpointDurably(
                        checkpoint,
                        for: recordingID,
                        completedChunksAtAttemptStart: completedChunksAtAttemptStart
                    )
                }
            )
            await drainEvents()

            try saveTranscript(output, for: recording)
            AppLog.transcription.atNotice.notice("VM: transcribe succeeded id=\(recordingID, privacy: .public) segments=\(output.segments.count, privacy: .public)")
            appSettings?.recordTranscriptionEngineUsed(config.transcription)
            if let settings = appSettings {
                startPostTranscriptionWork(for: recording, settings: settings)
            }
        } catch is CancellationError {
            await drainEvents()
            finishCancelled(recording, id: recordingID)
        } catch let appError as AppError {
            await drainEvents()
            if Self.isResumableCancellation(appError) {
                finishCancelled(recording, id: recordingID)
            } else {
                // Failed — but the checkpoint is kept, so a manual retry
                // resumes from the last completed chunk.
                recording.transcriptionStatus = .failed
                persist()
                error = appError
                let context = Self.logContext(for: appError)
                AppLog.transcription.atError.error("VM: transcribe failed (AppError) id=\(recordingID, privacy: .public) context=\(context, privacy: .public): \(appError.errorDescription ?? "nil", privacy: .public)")
            }
        } catch {
            await drainEvents()
            recording.transcriptionStatus = .failed
            persist()
            self.error = .transcriptionFailed(error.localizedDescription)
            AppLog.transcription.atError.error("VM: transcribe failed id=\(recordingID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Continue optional enrichment after the authoritative transcript has been
    /// persisted and the transcription task has returned to the UI. Each step is
    /// best-effort and exposes its own state; failures never mutate transcription
    /// status and do not prevent later steps from being attempted.
    private func startPostTranscriptionWork(for recording: Recording, settings: AppSettings) {
        guard let meeting = recording.meeting else { return }
        let recordingID = recording.id
        let meetingID = meeting.id
        let runID = UUID()

        postTranscriptionTasks[recordingID]?.cancel()
        postTranscriptionMeetingIDs[recordingID] = meetingID
        postTranscriptionRunIDs[recordingID] = runID
        postTranscriptionTasks[recordingID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.postTranscriptionRunIDs[recordingID] == runID {
                    self.postTranscriptionPhases[recordingID] = nil
                    self.postTranscriptionTasks[recordingID] = nil
                    self.postTranscriptionMeetingIDs[recordingID] = nil
                    self.postTranscriptionRunIDs[recordingID] = nil
                }
            }

            if self.shouldGenerateAITitle(for: meeting, settings: settings) {
                self.postTranscriptionPhases[recordingID] = .generatingTitle
                await self.generateAITitle(for: meeting, settings: settings)
            }
            guard !Task.isCancelled else { return }

            if settings.semanticSearchEnabled, let semanticIndexCoordinator = self.semanticIndexCoordinator {
                self.postTranscriptionPhases[recordingID] = .indexing
                await semanticIndexCoordinator.index(meeting)
            }
            guard !Task.isCancelled else { return }

            if self.shouldGenerateWiki(settings: settings),
               let wikiCoordinator = self.wikiCoordinator {
                self.postTranscriptionPhases[recordingID] = .generatingWiki
                await wikiCoordinator.generate(meeting)
            }
        }
    }

    /// Stop enrichment based on a now-stale transcript before re-transcribing any
    /// recording in the same meeting.
    private func cancelPostTranscriptionWork(for meetingID: UUID?) {
        guard let meetingID else { return }
        let staleRecordingIDs = postTranscriptionMeetingIDs.compactMap { recordingID, candidateMeetingID in
            candidateMeetingID == meetingID ? recordingID : nil
        }
        for recordingID in staleRecordingIDs {
            postTranscriptionTasks[recordingID]?.cancel()
            postTranscriptionPhases[recordingID] = nil
        }
    }

    private func shouldGenerateAITitle(for meeting: Meeting, settings: AppSettings) -> Bool {
        meeting.aiTitle == nil
            && meeting.hasAnyTranscript
            && settings.aiProvider.isUsable
    }

    private func shouldGenerateWiki(settings: AppSettings) -> Bool {
        settings.wikiEnabled
            && settings.aiProvider.isUsable
    }

    /// Settle a run that ended in cancellation. Which of the two cancellation
    /// kinds it was is recorded in `stoppingIDs` by `stopTranscription`, and both
    /// the `CancellationError` and the `AppError`-wrapped path land here — they
    /// must stay in agreement, which is why this is one function.
    private func finishCancelled(_ recording: Recording, id recordingID: UUID) {
        if stoppingIDs.remove(recordingID) != nil {
            // Full stop: discard the checkpoint so the next run starts fresh.
            recording.transcriptionCheckpointData = nil
            recording.transcriptionStatus = .none
            AppLog.transcription.atNotice.notice("VM: transcribe stopped id=\(recordingID, privacy: .public)")
        } else {
            // Paused: chunk progress is already checkpointed and `.pending`
            // gets picked up by the next foreground resume pass.
            recording.transcriptionStatus = .pending
            AppLog.transcription.atNotice.notice("VM: transcribe paused id=\(recordingID, privacy: .public)")
        }
        persist()
    }

    /// Persist a finished pipeline run: replace any existing transcript, mark
    /// the recording done, and drop its resume checkpoint.
    ///
    /// Throws if the new segments can't be encoded (`JSONStorage.
    /// encodeAuthoritative`), checked before touching the existing
    /// transcript so a bad result can't destroy a still-valid one.
    private func saveTranscript(_ output: TranscriptionService.Output, for recording: Recording) throws {
        guard let segmentsData = JSONStorage.encodeAuthoritative(output.segments) else {
            throw AppError.persistenceFailed(NSLocalizedString("error.transcript_encode_failed", comment: "Encode failed"))
        }

        // Replace any existing transcript. Detach the old one first: a
        // `delete` isn't applied to the relationship until the next save, so
        // without this `recording.transcript` still points at the old
        // transcript when the new one's inverse is established — which traps
        // with "relationship already has a value but it's not the target".
        if let existing = recording.transcript {
            recording.transcript = nil
            modelContext.delete(existing)
        }
        // Assigning `recording` establishes the relationship; `segments`
        // stays at its `[]` default, overwritten below with the
        // already-encoded, pre-checked bytes.
        let transcript = Transcript(recording: recording, language: output.language)
        transcript.segmentsData = segmentsData
        // Written in the same save as the segments, so a transcript can never
        // be durable while the record of how it was produced is missing. A
        // failed encode leaves it `nil` — "unknown", which is what a reader
        // must not be able to mistake for "clean" — instead of failing the
        // save and losing the transcript over a diagnostic payload.
        transcript.pipelineReportData = JSONStorage.encodeAuthoritative(output.report)
        if transcript.pipelineReportData == nil {
            AppLog.transcription.atError.error("VM: pipeline report encode failed; transcript stored without a run report")
        }
        modelContext.insert(transcript)
        recording.transcriptionStatus = .done
        recording.transcriptionCheckpointData = nil
        // Clear the AI title so re-transcription regenerates it from the new transcript.
        recording.meeting?.aiTitle = nil

        // Persisted on the recording (not just handed to syncSpeakers) so this
        // run's voiceprints are still available the next time any *other*
        // recording in the meeting is (re-)synced — see `Recording.speakerVoiceprints`.
        recording.speakerVoiceprints = output.speakerVoiceprints
        syncSpeakers(for: recording.meeting)
        persist()
    }

    /// Generate and persist a short AI-derived meeting title after transcription.
    /// Best-effort: errors are logged and swallowed so a failed title never
    /// blocks or surfaces as a user-facing error.
    private func generateAITitle(for meeting: Meeting?, settings: AppSettings) async {
        guard let meeting,
              let title = await aiTitleCoordinator.generateTitle(
                for: meeting,
                settings: settings
              ),
              !Task.isCancelled else { return }
        meeting.aiTitle = title
        persist()
        AppLog.transcription.atNotice.notice("VM: AI title id=\(meeting.id, privacy: .public) \"\(title, privacy: .private)\"")
    }

    /// Whether an `AppError` should pause transcription (→ `.pending`) rather
    /// than fail it. Only explicit task cancellation is resumable; a timeout can
    /// mean the provider processed a paid request whose response was lost.
    static func isResumableCancellation(_ error: AppError) -> Bool {
        if case .networkError(let urlError) = error {
            return urlError.code == .cancelled
        }
        return false
    }

    /// A concise, log-friendly description of the failure category so logs and
    /// bug reports can distinguish missing keys, API errors, network issues, etc.
    private static func logContext(for error: AppError) -> String {
        switch error {
        case .noAPIKey(let provider):
            return "missing API key for \(provider)"
        case .apiError(let status, let message):
            return "provider API error \(status): \(message)"
        case .networkError(let urlError):
            return "network error \(urlError.code.rawValue): \(urlError.localizedDescription)"
        case .transcriptionFailed(let detail):
            return "transcription engine failed: \(detail)"
        case .audioError(let detail):
            return "audio error: \(detail)"
        case .decodingError(let detail):
            return "decoding error: \(detail)"
        case .resourceUnavailable(let detail):
            return "resource unavailable: \(detail)"
        case .transcriptIntegrityFailed(let reason):
            return "integrity gate rejected output: \(reason)"
        default:
            return error.errorDescription ?? "unknown"
        }
    }

    /// Re-transcribe every recording of a meeting, in chronological order. Each
    /// segment runs through `transcribe`, which replaces its existing transcript,
    /// so the whole meeting is reprocessed (e.g. after the pipeline settings
    /// changed). Sequential by design: it respects the per-recording
    /// `transcribingIDs` guard and avoids saturating the network on the chunked
    /// Whisper path.
    func retranscribeAll(
        _ meeting: Meeting,
        language: MeetingLanguage,
        config: PipelineConfiguration
    ) async {
        for recording in meeting.recordings.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            // A deliberate user action, so it gets a fresh automatic-resume
            // budget the same as any other manual retry (H4).
            resetAutomaticResumeBudget(for: recording)
            // Through the task registry (not a bare `transcribe`) so the
            // background-window expiration handler can pause these runs too.
            startTranscription(recording, language: language, config: config)
            if let task = transcriptionTasks[recording.id] {
                await task.value
            }
        }
    }

    /// Reconcile the meeting's `Speaker` rows with the labels present across all
    /// its recordings' current transcripts, keeping each row attached to the
    /// person it belongs to rather than to the label it happened to have.
    ///
    /// The label is not an identity. The diarizer hands out `"Speaker N"` in
    /// order of first appearance, freshly on every run — **independently per
    /// recording** — so a re-transcription routinely renames the same voice,
    /// and two different recordings' own "Speaker 1" are two different people
    /// unless a voice says otherwise. This method used to key rows on the
    /// label string in the only two ways available, both wrong: deleting a row
    /// whose label stopped appearing threw away the name the user typed, and
    /// keeping a row under its old label would hand that name to whoever the
    /// diarizer now calls Speaker 2 — or, across recordings, to a completely
    /// different person who happened to get the same number.
    ///
    /// So the reconciliation is by voice when there is one, and it runs **one
    /// recording at a time**, in `recordedAt` order: each recording's own
    /// labels are matched, via `SpeakerIdentityMatcher`, only against
    /// whichever stored rows an *earlier* recording in this same pass hasn't
    /// already claimed. `Recording.speakerVoiceprints` is what makes that
    /// possible — every recording keeps its own diarization run's voiceprints,
    /// not just the one that just finished — so a second recording's
    /// "Speaker 1" is judged on its own voice instead of being merged, by
    /// label string alone, into whatever "Speaker 1" the first recording
    /// already produced.
    ///
    /// Where no voiceprint exists (the heuristic engine, or a transcript from
    /// before this existed) identity genuinely cannot be recovered, and guessing
    /// would be the error the matching exists to prevent. There the rule is only
    /// the conservative half: a row the user has named is never deleted, and a
    /// label already claimed within this pass is never handed to a second,
    /// different recording's same-numbered speaker.
    ///
    /// Internal rather than private so the behaviour that used to lose a typed
    /// name — or attach it to the wrong person — can be pinned by a test
    /// against a real `ModelContainer`.
    func syncSpeakers(for meeting: Meeting?) {
        guard let meeting else { return }

        // Snapshot the rows before anything moves: the matching is keyed on
        // what each row was called going in, and rows are relabelled below.
        let rows = meeting.speakers.map { (speaker: $0, original: $0.label) }

        var assignment: [String: Speaker] = [:]
        var claimedLabels: Set<String> = []
        var placed: Set<ObjectIdentifier> = []
        func isPlaced(_ speaker: Speaker) -> Bool { placed.contains(ObjectIdentifier(speaker)) }

        // A label already claimed within this pass gets a fresh one instead of
        // colliding — the only way two different recordings' independently
        // numbered "Speaker 1"s can both survive as distinct rows.
        func canonicalLabel(preferring raw: String) -> String {
            guard claimedLabels.contains(raw) else { return raw }
            var index = 1
            while claimedLabels.contains("Speaker \(index)") { index += 1 }
            return "Speaker \(index)"
        }

        func place(_ speaker: Speaker, rawLabel: String, canonical: String, voiceprints: [String: [Float]]) {
            assignment[canonical] = speaker
            claimedLabels.insert(canonical)
            placed.insert(ObjectIdentifier(speaker))
            // Refresh with this recording's own embedding: a speaker heard
            // again is described better by the newer one than by whichever
            // was stored first.
            if let vector = voiceprints[rawLabel] {
                speaker.voiceprintData = VectorData.encode(vector)
            }
        }

        var byVoiceCount = 0
        var unclaimed: [(label: String, voiceprint: [Float]?)] = []

        for recording in meeting.recordings.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard let segments = recording.transcript?.segments, !segments.isEmpty else { continue }

            // This recording's own labels, in first-appearance order — not
            // merged with any other recording's, since the diarizer numbers
            // them independently per run.
            var recordingLabels: [String] = []
            for segment in segments where !recordingLabels.contains(segment.speakerLabel) {
                recordingLabels.append(segment.speakerLabel)
            }
            let recordingVoiceprints = recording.speakerVoiceprints

            // Which row is which person, by voice — over *every* row with a
            // voiceprint, placed or not. A row an earlier recording in this
            // pass already placed can still be recognized by a later
            // recording's own run: that's what lets the same voice be
            // reunified across recordings regardless of which number each
            // one's diarizer gave it. Run over every label this recording
            // produced, not only the ones that appear or disappear: the
            // common case is the label set staying the same while the
            // assignment permutes, and matching only the leftovers would
            // miss exactly that.
            let matches = SpeakerIdentityMatcher.match(
                existing: rows.compactMap { row -> SpeakerIdentityMatcher.Candidate? in
                    guard let voiceprint = row.speaker.voiceprint else { return nil }
                    return SpeakerIdentityMatcher.Candidate(label: row.original, voiceprint: voiceprint)
                },
                incoming: recordingLabels.compactMap { label -> SpeakerIdentityMatcher.Candidate? in
                    guard let voiceprint = recordingVoiceprints[label] else { return nil }
                    return SpeakerIdentityMatcher.Candidate(label: label, voiceprint: voiceprint)
                }
            )
            byVoiceCount += matches.count

            // This recording's own raw labels that found a person this pass —
            // by voice below, or by the label fallback after it — so the
            // "nobody claimed this" step at the end only sees genuine leftovers.
            var consumed: Set<String> = []

            // 1. Voice wins. It is the only evidence here that identifies a
            // person. A fresh match places the row under a (collision-free)
            // canonical label; a match onto a row already placed this pass is
            // just a reconfirmation — same person, refresh the voiceprint,
            // don't relabel or duplicate.
            for row in rows {
                guard let raw = matches[row.original] else { continue }
                consumed.insert(raw)
                if isPlaced(row.speaker) {
                    if let vector = recordingVoiceprints[raw] {
                        row.speaker.voiceprintData = VectorData.encode(vector)
                    }
                    continue
                }
                let canonical = canonicalLabel(preferring: raw)
                place(row.speaker, rawLabel: raw, canonical: canonical, voiceprints: recordingVoiceprints)
                if canonical != row.original {
                    AppLog.transcription.atNotice.notice("VM: syncSpeakers \(row.original, privacy: .public) -> \(canonical, privacy: .public) by voice")
                }
            }
            // 2. Then the label, for rows no voiceprint could speak for — the
            // old behaviour, and still right when nothing has been renumbered.
            // Scoped to *this* recording's own, still-unconsumed labels, so a
            // later recording can never steal a row an earlier one already
            // claimed just because the diarizer handed out the same number
            // again.
            for row in rows where !isPlaced(row.speaker) {
                guard recordingLabels.contains(row.original),
                      !consumed.contains(row.original),
                      !claimedLabels.contains(row.original) else { continue }
                place(row.speaker, rawLabel: row.original, canonical: row.original, voiceprints: recordingVoiceprints)
                consumed.insert(row.original)
            }

            // Whatever this recording produced that no row claimed becomes a
            // new row below — never merged, by raw label string, into another
            // recording's leftover of the same name.
            for label in recordingLabels where !consumed.contains(label) {
                unclaimed.append((label, recordingVoiceprints[label]))
            }
        }

        for (label, speaker) in assignment {
            speaker.label = label
        }

        // 3. Rows with nowhere to go. An unnamed one holds nothing but a label
        // that no longer means anything; a named one holds what the user typed,
        // and losing that silently is the failure this method exists to prevent.
        var keptNamed = 0
        var removed = 0
        for row in rows where !isPlaced(row.speaker) {
            guard row.speaker.name.isEmpty else {
                keptNamed += 1
                continue
            }
            modelContext.delete(row.speaker)
            removed += 1
        }

        // 4. Rows for labels nobody claimed. The color index counts the rows
        // that will actually remain — deletes above aren't applied until save,
        // so `meeting.speakers` can't be counted for this. A brand-new row is
        // also checked against every *other* meeting's named speakers here
        // (D6, see TranscriptionViewModel+CrossMeetingSpeakerMatch.swift);
        // `crossMeetingCandidates` is fetched once, not per entry.
        let crossMeetingCandidates = unclaimed.contains { $0.voiceprint != nil }
            ? crossMeetingSpeakerCandidates(excluding: meeting)
            : []
        var index = assignment.count
        var addedLabels: [String] = []
        for entry in unclaimed {
            let canonical = canonicalLabel(preferring: entry.label)
            // Setting `meeting` establishes the relationship; SwiftData maintains
            // the inverse `meeting.speakers`.
            let speaker = Speaker(
                meeting: meeting,
                label: canonical,
                color: Color.speakerHex(for: index),
                voiceprintData: entry.voiceprint.map(VectorData.encode)
            )
            modelContext.insert(speaker)
            claimedLabels.insert(canonical)
            addedLabels.append(canonical)
            index += 1
            stageCrossMeetingMatchIfPossible(for: speaker, voiceprint: entry.voiceprint, among: crossMeetingCandidates)
        }

        // Final state the UI (filter chips + speaker list) will render, plus the
        // delta, so a "UI shows 1 speaker" report can be traced to the exact stage:
        // if `final` here is >1 the data layer is correct and any UI mismatch is a
        // view-refresh problem; if it's 1, the collapse happened upstream (see the
        // diarizer's `turnSpeakers`/`speakers` log lines).
        let finalLabels = claimedLabels.sorted()
        AppLog.transcription.atNotice.notice("VM: syncSpeakers final=\(finalLabels.count, privacy: .public) [\(finalLabels.joined(separator: ", "), privacy: .public)] added=\(addedLabels.count, privacy: .public) removed=\(removed, privacy: .public) byVoice=\(byVoiceCount, privacy: .public) keptNamed=\(keptNamed, privacy: .public)")
    }
}
