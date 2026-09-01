//
//  TranscriptionServiceCorrection.swift
//  Kurn
//
//  The optional LLM correction stage and the typed report entry it produces
//  (H5 PR 11). Extracted from `TranscriptionService.transcribe` for the same
//  reason `TranscriptionServiceInputPreparation.swift` was: recording an
//  outcome per stage pushed one already-long function past SwiftLint's
//  body-length limit.
//

import Foundation
import KurnCore

extension TranscriptionService {
    /// Corrected segments plus what the correction stage actually did — the
    /// segments alone cannot say, since "nothing changed" is both a clean pass
    /// and what an unusable provider leaves behind.
    struct CorrectionStep: Sendable {
        var segments: [TranscriptSegment]
        var stage: PipelineStageReport
    }

    /// Correct transcription errors (spelling, punctuation, homophones,
    /// obvious ASR mistakes) on already-fused, speaker-attributed segments.
    ///
    /// `TranscriptCorrecting` conformers never throw and always return
    /// `segments.count` segments in order, so a failure here degrades to "no
    /// correction ran" instead of failing the transcription — the returned
    /// report entry is what records which of the two happened.
    func correctIfRequested(
        segments: [TranscriptSegment],
        language: MeetingLanguage,
        config: PipelineConfiguration,
        onPhase: @escaping PhaseHandler
    ) async throws -> CorrectionStep {
        let engine = config.effectiveCorrection
        if engine != .none {
            onPhase(.correcting(progress: nil))
        }
        let correction = await resolveCorrector(engine).correct(
            segments: segments,
            language: language,
            provider: config.correctionProvider,
            model: config.correctionModel,
            onProgress: { progress in
                guard engine != .none else { return }
                onPhase(.correcting(progress: progress))
            }
        )
        // The corrector cannot throw, so a run cancelled between batches comes
        // back with partially corrected segments and an outcome that says
        // nothing about it. Cancellation is not a stage result and must never
        // be recorded as one — it ends the run here, as in every other stage.
        try Task.checkCancellation()
        // A requested engine that `effectiveCorrection` stepped down is a
        // degradation the corrector itself never sees: it was handed the no-op
        // engine and correctly reports "not requested".
        let steppedDown = config.correction != .none && engine == .none
        return CorrectionStep(
            segments: correction.segments,
            stage: PipelineStageReport(
                stage: .correction,
                outcome: steppedDown ? .degraded : correction.outcome,
                requestedEngine: config.correction.rawValue,
                effectiveEngine: engine.rawValue,
                reason: steppedDown ? .providerUnavailable : correction.reason
            )
        )
    }
}
