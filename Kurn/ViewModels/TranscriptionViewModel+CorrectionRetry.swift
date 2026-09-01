//
//  TranscriptionViewModel+CorrectionRetry.swift
//  Kurn
//
//  Retries only the correction stage over an already-saved transcript (H5 PR
//  13): the one pipeline stage that needs nothing but its own segments and
//  language, so a `.degraded`/`.failed` correction entry can be redone
//  without repeating audio preprocessing, ASR, or diarization. Every other
//  stage's warning falls back to a full re-transcribe — the architecture has
//  no seam to re-run just one of them. Split out of `TranscriptionViewModel.swift`
//  for the same file-length reason as its other `+`-extension siblings.
//

import Foundation
import KurnCore

extension TranscriptionViewModel {
    /// Re-runs `TranscriptionService.correctIfRequested` over `recording`'s
    /// current transcript segments and, on success, replaces just the
    /// correction entry of its `PipelineReport` — the rest of the report is
    /// untouched, since nothing else ran.
    ///
    /// `correctIfRequested` already enforces `TranscriptIntegrityGate
    /// .correctionPreservedIdentity` before trusting its own result, so
    /// anything it returns is either `original` unchanged or `original` with
    /// only `.text` fields replaced — timestamps, ids, and speaker labels
    /// can't have moved. The gate below therefore only needs a sanity bound
    /// derived from `original`'s own timeline, not the source audio: every
    /// timestamp already in `original` is by construction within it.
    func retryCorrection(_ recording: Recording, language: MeetingLanguage, config: PipelineConfiguration) {
        let recordingID = recording.id
        guard let transcript = recording.transcript, !transcript.segments.isEmpty,
              !correctionRetryIDs.contains(recordingID) else { return }
        let original = transcript.segments
        correctionRetryIDs.insert(recordingID)
        Task { [weak self] in
            guard let self else { return }
            defer { self.correctionRetryIDs.remove(recordingID) }
            do {
                let step = try await self.transcriptionService.correctIfRequested(
                    segments: original,
                    language: language,
                    config: config,
                    onPhase: { _ in }
                )
                try Task.checkCancellation()
                let sourceDuration = original.map(\.endTime).max() ?? 0
                if let failure = TranscriptIntegrityGate.validate(
                    segments: step.segments,
                    sourceDuration: sourceDuration,
                    hadTranscribedInput: !original.isEmpty
                ) {
                    AppLog.transcription.atError.error("retryCorrection: integrity gate rejected output: \(failure.rawValue, privacy: .public)")
                    self.error = .transcriptIntegrityFailed(failure.rawValue)
                    return
                }
                // Re-fetch rather than reuse the captured `transcript`: the
                // recording could have been re-transcribed (a new Transcript
                // row) while this retry was in flight.
                guard let liveTranscript = recording.transcript, liveTranscript.segments == original else {
                    return
                }
                liveTranscript.segments = step.segments
                var builder = PipelineReportBuilder()
                builder.record(contentsOf: (liveTranscript.pipelineReport ?? PipelineReport()).stages)
                builder.record(step.stage)
                liveTranscript.pipelineReportData = JSONStorage.encodeAuthoritative(builder.report)
                self.persist()
            } catch is CancellationError {
                // Silent, same as every other cancellable pipeline call.
            } catch let appError as AppError {
                self.error = appError
            } catch {
                self.error = .transcriptionFailed(error.localizedDescription)
            }
        }
    }
}
