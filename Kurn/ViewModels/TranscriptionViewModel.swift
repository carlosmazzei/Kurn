//
//  TranscriptionViewModel.swift
//  Kurn
//
//  Coordinates transcription and summary generation for a meeting and writes the
//  results back into SwiftData. Heavy work runs in the value-type services off
//  the main actor; all model mutation happens here on the main actor.
//

import Foundation
import Observation
import SwiftData
import SwiftUI // for Color.speakerHex palette helper

@MainActor
@Observable
final class TranscriptionViewModel {
    /// IDs of recordings currently transcribing, for per-row spinners.
    private(set) var transcribingIDs: Set<UUID> = []
    /// Active pipeline phase per recording, so the UI can show the current stage.
    private(set) var phases: [UUID: TranscriptionPhase] = [:]
    private(set) var isSummarizing = false
    /// Staged-summary progress as (stage, total) when a long transcript is
    /// being summarized in parts; nil for single-pass summaries.
    private(set) var summaryProgress: (stage: Int, total: Int)?
    var error: AppError?
    /// Non-fatal diarization failures (e.g. a FluidAudio model download error),
    /// keyed by recording so concurrent transcriptions of different recordings
    /// never clobber or misattribute each other's warning. Transcription still
    /// succeeds; this is a banner, not an `AppError`.
    private(set) var diarizationWarnings: [UUID: String] = [:]

    /// Task handles for transcriptions started via `startTranscription`, so
    /// they can be cancelled (by the user or by the background window expiring).
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Recordings this instance is transcribing, so `@Sendable` pipeline
    /// callbacks can reach the model by ID after hopping to the main actor.
    private var activeRecordings: [UUID: Recording] = [:]
    /// Recordings in flight across ALL instances — `MeetingDetailView` creates
    /// a view model per screen and the app-level resume coordinator has its
    /// own, and a recording must never transcribe twice concurrently.
    private static var globalActiveIDs: Set<UUID> = []

    private let modelContext: ModelContext
    private let transcriptionService = TranscriptionService()
    private let summaryService = SummaryService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Persist pending model changes, surfacing failures instead of dropping
    /// them silently — a failed save otherwise leaves the in-memory models and
    /// the store diverged (e.g. status shown as `.done` but stored as `.inProgress`).
    private func persist() {
        do {
            try modelContext.save()
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
        }
    }

    func isTranscribing(_ recording: Recording) -> Bool {
        transcribingIDs.contains(recording.id)
    }

    /// The pipeline stage currently running for a recording, if any.
    func phase(for recording: Recording) -> TranscriptionPhase? {
        phases[recording.id]
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
        let recordingID = recording.id
        guard transcriptionTasks[recordingID] == nil,
              !Self.globalActiveIDs.contains(recordingID) else { return }
        transcriptionTasks[recordingID] = Task { [weak self] in
            await self?.transcribe(recording, language: language, config: config)
            self?.transcriptionTasks[recordingID] = nil
        }
    }

    /// Cancel an in-flight transcription started via `startTranscription`.
    /// Progress up to the last completed chunk stays in the checkpoint and the
    /// recording is left `.pending`, so a later run resumes rather than restarts.
    func cancelTranscription(_ recording: Recording) {
        transcriptionTasks[recording.id]?.cancel()
    }

    func transcribe(
        _ recording: Recording,
        language: MeetingLanguage,
        config: PipelineConfiguration
    ) async {
        guard !transcribingIDs.contains(recording.id),
              !Self.globalActiveIDs.contains(recording.id) else { return }

        let recordingID = recording.id
        AppLog.transcription.atNotice.notice("VM: transcribe requested id=\(recordingID, privacy: .public) engine=\(config.transcription.rawValue, privacy: .public)")

        transcribingIDs.insert(recordingID)
        Self.globalActiveIDs.insert(recordingID)
        activeRecordings[recordingID] = recording
        phases[recordingID] = .preparing
        defer {
            transcribingIDs.remove(recordingID)
            Self.globalActiveIDs.remove(recordingID)
            activeRecordings[recordingID] = nil
            phases[recordingID] = nil
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
        // already-transcribed chunks when it still matches.
        let checkpoint = recording.transcriptionCheckpoint
        if let checkpoint {
            AppLog.transcription.atNotice.notice("VM: checkpoint found id=\(recordingID, privacy: .public) chunks=\(checkpoint.completedChunks, privacy: .public)/\(checkpoint.totalChunks, privacy: .public)")
        }

        // Long transcriptions (especially the chunked Whisper path) would
        // otherwise be aborted when the app is backgrounded and the system
        // suspends it. Hold a background-task assertion for the duration so the
        // work gets a finite grace window; when the system reclaims it, cancel
        // the run so it checkpoints as `.pending` (resumed on next foreground)
        // instead of freezing mid-chunk.
        let background = BackgroundActivity()
        background.begin(name: "ai.kurn.transcription") { [weak self] in
            self?.transcriptionTasks[recordingID]?.cancel()
        }
        defer { background.end() }

        do {
            let output = try await transcriptionService.transcribe(
                fileURL: fileURL,
                fileName: fileName,
                language: language,
                config: config,
                checkpoint: checkpoint,
                onPhase: { [weak self] phase in
                    // Reported off the main actor; hop back before mutating state.
                    Task { @MainActor in self?.phases[recordingID] = phase }
                },
                onDiarizationWarning: { [weak self] message in
                    Task { @MainActor in self?.diarizationWarnings[recordingID] = message }
                },
                onCheckpoint: { [weak self] checkpoint in
                    Task { @MainActor in self?.storeCheckpoint(checkpoint, for: recordingID) }
                }
            )

            saveTranscript(output, for: recording)
            AppLog.transcription.atNotice.notice("VM: transcribe succeeded id=\(recordingID, privacy: .public) segments=\(output.segments.count, privacy: .public)")
        } catch is CancellationError {
            // Paused, not failed: chunk progress is already checkpointed, and
            // `.pending` gets picked up by the next foreground resume pass.
            recording.transcriptionStatus = .pending
            persist()
            AppLog.transcription.atNotice.notice("VM: transcribe paused id=\(recordingID, privacy: .public)")
        } catch let appError as AppError {
            if isCancellation(appError) {
                recording.transcriptionStatus = .pending
                persist()
                AppLog.transcription.atNotice.notice("VM: transcribe paused id=\(recordingID, privacy: .public)")
            } else {
                // Failed — but the checkpoint is kept, so a manual retry
                // resumes from the last completed chunk.
                recording.transcriptionStatus = .failed
                persist()
                error = appError
                AppLog.transcription.atError.error("VM: transcribe failed (AppError) id=\(recordingID, privacy: .public): \(appError.errorDescription ?? "nil", privacy: .public)")
            }
        } catch {
            recording.transcriptionStatus = .failed
            persist()
            self.error = .transcriptionFailed(error.localizedDescription)
            AppLog.transcription.atError.error("VM: transcribe failed id=\(recordingID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a finished pipeline run: replace any existing transcript, mark
    /// the recording done, and drop its resume checkpoint.
    private func saveTranscript(_ output: TranscriptionService.Output, for recording: Recording) {
        // Replace any existing transcript. Detach the old one first: a
        // `delete` isn't applied to the relationship until the next save, so
        // without this `recording.transcript` still points at the old
        // transcript when the new one's inverse is established — which traps
        // with "relationship already has a value but it's not the target".
        if let existing = recording.transcript {
            recording.transcript = nil
            modelContext.delete(existing)
        }
        // Assigning `recording` in the initializer establishes the
        // relationship (SwiftData maintains the inverse `recording.transcript`),
        // so no manual back-assignment is needed.
        let transcript = Transcript(
            recording: recording,
            segments: output.segments,
            language: output.language
        )
        modelContext.insert(transcript)
        recording.transcriptionStatus = .done
        recording.transcriptionCheckpointData = nil

        syncSpeakers(for: recording.meeting)
        persist()
    }

    /// Whether an `AppError` is really the transcription task being cancelled
    /// (URLSession surfaces cancellation of an in-flight upload as a network
    /// error rather than `CancellationError`).
    private func isCancellation(_ error: AppError) -> Bool {
        if case .networkError(let urlError) = error {
            return urlError.code == .cancelled
        }
        return false
    }

    /// Persist chunk progress reported by the pipeline so an interruption at
    /// any point resumes from the last completed chunk.
    private func storeCheckpoint(_ checkpoint: TranscriptionCheckpoint, for id: UUID) {
        guard let recording = activeRecordings[id] else { return }
        recording.transcriptionCheckpoint = checkpoint
        persist()
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
            startTranscription(
                recording,
                language: recording.meeting?.language ?? .autoDetect,
                config: settings.pipelineConfiguration
            )
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
            await transcribe(recording, language: language, config: config)
        }
    }

    /// Reconcile the meeting's `Speaker` rows with the labels actually present
    /// across all its recordings' current transcripts. Adds rows for new labels
    /// and removes any whose label no longer appears in *any* transcript — so a
    /// re-transcription that detects a different (e.g. smaller) set of speakers
    /// doesn't leave stale chips/rows behind in the UI. Labels that survive keep
    /// their existing row, preserving the user's renamed `name` and color.
    ///
    /// Speakers are meeting-scoped but transcripts are per-recording, so the
    /// "still used" set is the union over every recording: re-transcribing one
    /// recording must not drop speakers another recording still references.
    private func syncSpeakers(for meeting: Meeting?) {
        guard let meeting else { return }

        // Labels still referenced by any recording's current transcript, in
        // first-appearance order for stable color assignment.
        var usedLabels: [String] = []
        for recording in meeting.recordings.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard let segments = recording.transcript?.segments else { continue }
            for segment in segments where !usedLabels.contains(segment.speakerLabel) {
                usedLabels.append(segment.speakerLabel)
            }
        }

        // Drop speakers no longer referenced by any transcript.
        let existingLabels = Set(meeting.speakers.map(\.label))
        let deletedLabels = existingLabels.subtracting(usedLabels)
        for speaker in meeting.speakers where !usedLabels.contains(speaker.label) {
            modelContext.delete(speaker)
        }

        // Add rows for newly-appearing labels. `surviving` excludes the rows just
        // marked for deletion (the delete isn't applied until save) so the color
        // index reflects the speakers that will actually remain.
        let survivingLabels = existingLabels.subtracting(deletedLabels)
        var index = survivingLabels.count
        var addedLabels: [String] = []
        for label in usedLabels where !meeting.speakers.contains(where: { $0.label == label }) {
            // Setting `meeting` establishes the relationship; SwiftData maintains
            // the inverse `meeting.speakers`.
            let speaker = Speaker(
                meeting: meeting,
                label: label,
                color: Color.speakerHex(for: index)
            )
            modelContext.insert(speaker)
            addedLabels.append(label)
            index += 1
        }

        // Final state the UI (filter chips + speaker list) will render, plus the
        // delta, so a "UI shows 1 speaker" report can be traced to the exact stage:
        // if `final` here is >1 the data layer is correct and any UI mismatch is a
        // view-refresh problem; if it's 1, the collapse happened upstream (see the
        // diarizer's `turnSpeakers`/`speakers` log lines).
        AppLog.transcription.atNotice.notice("VM: syncSpeakers final=\(usedLabels.count, privacy: .public) [\(usedLabels.joined(separator: ", "), privacy: .public)] added=\(addedLabels.count, privacy: .public) removed=\(deletedLabels.count, privacy: .public)")
    }

    // MARK: - Summary

    func generateSummary(
        for meeting: Meeting,
        provider: AIProvider,
        model: String,
        template: SummaryTemplate
    ) async {
        guard !isSummarizing else { return }

        // Assemble transcript text on the main actor (reads SwiftData). Each
        // group carries the recording's absolute start offset so the timestamps
        // stay chronological across multiple segments.
        let groups: [(offset: TimeInterval, segments: [TranscriptSegment])] = meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording in
                guard let segments = recording.transcript?.segments else { return nil }
                return (offset: meeting.startOffset(of: recording), segments: segments)
            }
        let transcriptText = SummaryService.assembleTranscriptText(from: groups)
        let title = meeting.title

        guard !transcriptText.isEmpty else {
            error = .transcriptionFailed(
                NSLocalizedString("error.no_transcript", comment: "No transcript to summarize")
            )
            return
        }

        isSummarizing = true
        summaryProgress = nil
        AppLog.transcription.atNotice.notice("VM: summary start provider=\(provider.rawValue, privacy: .public) chars=\(transcriptText.count, privacy: .public)")
        do {
            let result = try await summaryService.generate(
                transcriptText: transcriptText,
                meetingTitle: title,
                provider: provider,
                model: model,
                template: template,
                onProgress: { [weak self] stage, total in
                    // Reported off the main actor; hop back before mutating state.
                    Task { @MainActor in self?.summaryProgress = (stage, total) }
                }
            )
            if let existing = meeting.summary {
                existing.sections = result.sections
                existing.templateName = template.displayName
                existing.provider = provider
                existing.model = model
                existing.updatedAt = Date()
            } else {
                let summary = Summary(
                    meeting: meeting,
                    sections: result.sections,
                    templateName: template.displayName,
                    provider: provider,
                    model: model
                )
                modelContext.insert(summary)
                meeting.summary = summary
            }
            persist()
            AppLog.transcription.atNotice.notice("VM: summary done")
        } catch let appError as AppError {
            error = appError
            AppLog.transcription.atError.error("VM: summary failed (AppError): \(appError.errorDescription ?? "nil", privacy: .public)")
        } catch {
            self.error = .apiError(statusCode: 0, message: error.localizedDescription)
            AppLog.transcription.atError.error("VM: summary failed: \(error.localizedDescription, privacy: .public)")
        }
        isSummarizing = false
        summaryProgress = nil
    }
}
