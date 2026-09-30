//
//  TranscriptionCoordinator.swift
//  Kurn
//
//  Owns every transcription run for the process: starting, pausing, stopping
//  and resuming it, persisting what the pipeline produced, reconciling the
//  meeting's speakers, and the best-effort enrichment that follows (AI title,
//  semantic index, wiki). Heavy work runs in the value-type services off the
//  main actor; all model mutation happens here on the main actor.
//
//  It used to be `TranscriptionViewModel`, which also generated and translated
//  summaries, and the `BGProcessingTask` runner depended on it — a lower layer
//  reaching up into a view model to transcribe. Transcription has no screen of
//  its own to serve: the scene and the background window drive the same runs,
//  so it lives in Application/ and `TranscriptionScheduler` depends on it
//  directly. Summary generation, which only the meeting screen starts, stayed
//  behind as `SummaryViewModel`. Its state is still `@Observable` because the
//  meeting screen renders per-recording progress straight from it.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class TranscriptionCoordinator {
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
    /// Failures not tied to any one recording — a generic `persist()` save
    /// (which commits whatever is pending across the whole context, not one
    /// recording's own changes) or an explicit AI title regeneration.
    var error: AppError?
    /// Transcription failures, keyed by recording (H9 PR 21) — split out of
    /// the single `error` above because `TranscriptionCoordinator` is one
    /// app-wide shared instance (`KurnApp`, injected via `.environment`, read
    /// by every `MeetingDetailView` through `@Environment`), so two different
    /// recordings transcribing concurrently used to be able to clobber or
    /// misattribute each other's failure through that one shared property —
    /// exactly `diarizationWarnings`' own problem below, generalized to
    /// blocking transcription errors. `MeetingDetailView` binds its
    /// `.errorAlert` to `transcriptionError(for:)`/`clearTranscriptionError(for:)`
    /// for the recording it's actually showing.
    private(set) var errorsByRecording: [UUID: AppError] = [:]
    /// Non-fatal diarization failures (e.g. a FluidAudio model download error),
    /// keyed by recording so concurrent transcriptions of different recordings
    /// never clobber or misattribute each other's warning. Transcription still
    /// succeeds; this is a banner, not an `AppError`.
    private(set) var diarizationWarnings: [UUID: String] = [:]
    /// A voiceprint match for a new `Speaker` row, found in a different
    /// meeting — staged, never silently applied. See
    /// `TranscriptionCoordinator+CrossMeetingSpeakerMatch.swift`.
    var pendingCrossMeetingMatches: [CrossMeetingSpeakerMatch] = []
    /// Recordings whose correction stage is currently being retried in
    /// isolation (H5 PR 13). Not `private(set)` —
    /// `TranscriptionCoordinator+CorrectionRetry.swift` needs to mutate it.
    var correctionRetryIDs: Set<UUID> = []

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
    /// Not `private` — `TranscriptionCoordinator+ResumeBudget.swift` needs it.
    var activeRecordings: [UUID: Recording] = [:]
    /// Recordings this instance is actually working on. The foreground
    /// recovery sweep uses this to distinguish a live run (leave alone) from a
    /// stale persisted `.inProgress` (reset to resumable). There is one
    /// instance per process — `KurnApp`'s `AppComposition` hands the same one
    /// to the scene and to the `BGProcessingTask` runner — so this per-instance
    /// set is also what keeps a recording from transcribing twice at once.
    var activeTranscriptionIDs: Set<UUID> { transcribingIDs }

    /// Not `private` — `TranscriptionCoordinator+CrossMeetingSpeakerMatch.swift`
    /// and `TranscriptionCoordinator+Speakers.swift` need it.
    let modelContext: ModelContext
    /// Not `private` — `TranscriptionCoordinator+CorrectionRetry.swift` needs
    /// it to retry just the correction stage without repeating the rest of
    /// the pipeline.
    let transcriptionService: TranscriptionService
    /// Not `private` — `TranscriptionCoordinator+AITitle.swift` needs it.
    let aiTitleCoordinator: AITitleCoordinator
    /// App-wide settings, injected at construction by `AppComposition` so
    /// usage stats and title generation never run against a missing value.
    /// `nil` only in tests that exercise the pipeline without preferences.
    let appSettings: AppSettings?
    /// App-wide semantic-index coordinator. A finished transcription updates
    /// the meeting's on-device index through it. `nil` only in tests.
    let semanticIndexCoordinator: SemanticIndexCoordinator?
    /// App-wide wiki coordinator. A finished transcription refreshes the
    /// meeting's condensed wiki article through it (opt-in). `nil` only in tests.
    let wikiCoordinator: WikiCoordinator?

    init(
        modelContext: ModelContext,
        appSettings: AppSettings? = nil,
        semanticIndexCoordinator: SemanticIndexCoordinator? = nil,
        wikiCoordinator: WikiCoordinator? = nil,
        aiTitleCoordinator: AITitleCoordinator = AITitleCoordinator(),
        transcriptionService: TranscriptionService = TranscriptionService()
    ) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.semanticIndexCoordinator = semanticIndexCoordinator
        self.wikiCoordinator = wikiCoordinator
        self.aiTitleCoordinator = aiTitleCoordinator
        self.transcriptionService = transcriptionService
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

    /// The transcription failure attributed to this recording, if any (H9 PR
    /// 21) — distinct from `error` so two different recordings' concurrent
    /// transcription failures can't clobber or misattribute each other.
    func transcriptionError(for recording: Recording) -> AppError? {
        errorsByRecording[recording.id]
    }

    func clearTranscriptionError(for recording: Recording) {
        errorsByRecording[recording.id] = nil
    }

    #if DEBUG
    /// Test-only: `transcribe()`'s real failure paths need the full pipeline
    /// running, so `KurnTests` sets `errorsByRecording` directly instead
    /// (see `TranscriptionCoordinatorErrorAttributionTests`) rather than
    /// widening the real API with a public setter.
    func setTranscriptionErrorForTesting(_ error: AppError, for recording: Recording) {
        errorsByRecording[recording.id] = error
    }
    #endif

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
              !transcribingIDs.contains(recordingID) else {
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
              !transcribingIDs.contains(recording.id) else { return }

        let recordingID = recording.id
        // H9 PR 22, item 5: one id correlates every `ReliabilityEvent` this
        // attempt produces (started through its terminal outcome), the same
        // "operation run" grouping `DocumentGenerationViewModel` already
        // established for its own operation.
        let runID = OperationID()
        let startedAt = Date()
        AppLog.transcription.atNotice.notice("VM: transcribe requested id=\(recordingID, privacy: .public) engine=\(config.transcription.rawValue, privacy: .public)")
        ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "transcription", outcome: .started))

        cancelPostTranscriptionWork(for: recording.meeting?.id)
        transcribingIDs.insert(recordingID)
        activeRecordings[recordingID] = recording
        phases[recordingID] = .preparing
        defer {
            transcribingIDs.remove(recordingID)
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
                AppLog.transcription.atError.error("VM: speech permission denied id=\(recordingID, privacy: .public)")
                recording.transcriptionStatus = .failed
                persist()
                // H9 PR 22: recording-scoped like the two failure paths
                // below (PR 21) — this is also a per-attempt failure tied
                // to one recording, not a `persist()`-shaped generic one.
                errorsByRecording[recordingID] = .permissionDenied(
                    NSLocalizedString("error.speech_permission", comment: "Speech permission")
                )
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "transcription", outcome: .failed,
                    elapsedSeconds: Date().timeIntervalSince(startedAt), code: AppError.permissionDenied("").logCode
                ))
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
        if checkpointOutcome.isUnreadable {
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
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "transcription", outcome: .succeeded,
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            appSettings?.recordTranscriptionEngineUsed(config.transcription)
            if let settings = appSettings {
                startPostTranscriptionWork(for: recording, settings: settings)
            }
        } catch is CancellationError {
            await drainEvents()
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "transcription", outcome: .cancelled,
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            finishCancelled(recording, id: recordingID)
        } catch let appError as AppError {
            await drainEvents()
            if Self.isResumableCancellation(appError) {
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "transcription", outcome: .cancelled,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                finishCancelled(recording, id: recordingID)
            } else {
                // Failed — but the checkpoint is kept, so a manual retry
                // resumes from the last completed chunk.
                recording.transcriptionStatus = .failed
                persist()
                errorsByRecording[recordingID] = appError
                let context = Self.logContext(for: appError)
                // H9 PR 22, item 5: log the content-free `logCode`, never
                // `errorDescription` — several `AppError` cases interpolate a
                // raw underlying error's own `localizedDescription` into
                // their safe user-facing text, which would otherwise reach
                // this `.public` line unredacted. The detail stays available
                // at `.private` for a developer with Console access and the
                // private-data profile, never in the default log stream.
                AppLog.transcription.atError.error("VM: transcribe failed (AppError) id=\(recordingID, privacy: .public) context=\(context, privacy: .public) code=\(appError.logCode, privacy: .public) detail=\(appError.privateContext ?? "", privacy: .private)")
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "transcription", outcome: .failed,
                    elapsedSeconds: Date().timeIntervalSince(startedAt), code: appError.logCode
                ))
            }
        } catch {
            await drainEvents()
            recording.transcriptionStatus = .failed
            persist()
            let wrapped = AppError.transcriptionFailed(error.localizedDescription)
            errorsByRecording[recordingID] = wrapped
            AppLog.transcription.atError.error("VM: transcribe failed id=\(recordingID, privacy: .public) code=\(wrapped.logCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "transcription", outcome: .failed,
                elapsedSeconds: Date().timeIntervalSince(startedAt), code: wrapped.logCode
            ))
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
}
