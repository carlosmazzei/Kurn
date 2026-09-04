//
//  TranscriptionServiceInputPreparation.swift
//  Kurn
//
//  The three deterministic stages that run before transcription — audio
//  cleanup, language detection, and voice-activity detection — plus the typed
//  stage reports they produce (H5 PR 11). Extracted from
//  `TranscriptionService.transcribe` for the same reason
//  `TranscriptionViewModel+Summary.swift` was: recording an outcome per stage
//  pushed one already-long function past SwiftLint's body-length limit.
//
//  Every branch that steps down here — cleanup failing and using the original
//  audio, a detector returning the caller's hint because it could not detect —
//  produces a report entry, because none of them are visible in the values the
//  stage returns.
//

import Foundation
import KurnCore

extension TranscriptionService {
    /// Everything the transcription and diarization stages need from the
    /// pre-transcription passes, plus what those passes did.
    struct PreparedInput: Sendable {
        /// Audio the transcription path should read: the cleaned copy, or the
        /// original when cleanup was disabled or failed. The caller owns
        /// cleanup, since it also owns the `defer` that fires it.
        var cleanedURL: URL
        /// The language hint refined by the detector, or the hint unchanged.
        var language: MeetingLanguage
        var regions: [SpeechRegion]
        var stages: [PipelineStageReport]
    }

    func prepareInput(
        fileURL: URL,
        config: PipelineConfiguration,
        language: MeetingLanguage,
        onPhase: @escaping PhaseHandler
    ) async throws -> PreparedInput {
        var stages: [PipelineStageReport] = []

        // 1. Clean the audio (selected preprocessing engine) for the
        // transcription path. If cleanup fails for any reason we fall back to
        // the original so transcription never breaks.
        onPhase(.preprocessing)
        let preprocessor = resolvePreprocessor(config.preprocessing)
        AppLog.transcription.atDebug.debug("transcribe: preprocessing (\(config.preprocessing.rawValue, privacy: .public))…")
        let preStart = Date()
        let cleanedURL: URL
        do {
            cleanedURL = try await preprocessor.process(url: fileURL)
            stages.append(Self.preprocessingReport(engine: config.preprocessing, usedOriginal: false))
            AppLog.transcription.atDebug.debug("transcribe: preprocessing done in \(Date().timeIntervalSince(preStart), privacy: .public)s")
        } catch is CancellationError {
            throw CancellationError()
        } catch let appError as AppError {
            if case .resourceUnavailable = appError { throw appError }
            cleanedURL = fileURL
            stages.append(Self.preprocessingReport(engine: config.preprocessing, usedOriginal: true))
            AppLog.transcription.atError.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original code=\(appError.logCode, privacy: .public) detail=\(appError.localizedDescription, privacy: .private)")
        } catch {
            try ResourceGuard.rethrowIfResourceFailure(error)
            cleanedURL = fileURL
            stages.append(Self.preprocessingReport(engine: config.preprocessing, usedOriginal: true))
            AppLog.transcription.atError.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
        try await ResourceGuard.requireTranscriptionHeadroom()

        // 2. Detect the language (selected engine) to refine the hint. The
        // default no-op detector returns the hint unchanged, deferring to the
        // transcription engine's own detection — so only surface the phase when a
        // real detector runs, otherwise the bar would flash a stage that does no
        // work.
        if config.languageDetection != .byTranscriber {
            onPhase(.detectingLanguage)
        }
        let detector = resolveLanguageDetector(config.languageDetection)
        let resolvedLanguage = await detector.detect(url: cleanedURL, hint: language)
        try Task.checkCancellation()
        stages.append(Self.languageDetectionReport(engine: config.languageDetection, hint: language, resolved: resolvedLanguage))
        if resolvedLanguage != language {
            AppLog.transcription.atInfo.info("transcribe: language refined \(language.rawValue, privacy: .public) -> \(resolvedLanguage.rawValue, privacy: .public)")
        }
        try await ResourceGuard.requireTranscriptionHeadroom()

        // 3. Detect speech regions with the selected VAD engine. They drive both
        // the heuristic diarizer's segmentation and the silence-gating of the
        // audio fed to transcription.
        onPhase(.detectingSpeech)
        let regions = await resolveVAD(config.vad).detectSpeech(url: cleanedURL)
        try Task.checkCancellation()
        stages.append(Self.voiceActivityReport(engine: config.vad, regions: regions))
        AppLog.transcription.atDebug.debug("transcribe: VAD (\(config.vad.rawValue, privacy: .public)) regions=\(regions.count, privacy: .public)")

        return PreparedInput(
            cleanedURL: cleanedURL,
            language: resolvedLanguage,
            regions: regions,
            stages: stages
        )
    }

    // MARK: - Stage reports

    private static func preprocessingReport(
        engine: PreprocessingEngine,
        usedOriginal: Bool
    ) -> PipelineStageReport {
        if usedOriginal {
            return PipelineStageReport(
                stage: .preprocessing,
                outcome: .degraded,
                requestedEngine: engine.rawValue,
                effectiveEngine: PreprocessingEngine.none.rawValue,
                reason: .originalAudioUsed
            )
        }
        return PipelineStageReport(
            stage: .preprocessing,
            outcome: engine == .none ? .skipped : .succeeded,
            requestedEngine: engine.rawValue,
            effectiveEngine: engine.rawValue,
            reason: engine == .none ? .notRequested : nil
        )
    }

    /// A `LanguageDetecting` conformer returns the hint unchanged when it
    /// cannot detect — its only failure signal — so an unchanged result is
    /// recorded as "the caller's hint was used", never as successful
    /// detection.
    private static func languageDetectionReport(
        engine: LanguageDetectionEngine,
        hint: MeetingLanguage,
        resolved: MeetingLanguage
    ) -> PipelineStageReport {
        guard engine != .byTranscriber else {
            return PipelineStageReport(
                stage: .languageDetection,
                outcome: .skipped,
                requestedEngine: engine.rawValue,
                effectiveEngine: engine.rawValue,
                reason: .notRequested
            )
        }
        let detected = resolved != hint
        return PipelineStageReport(
            stage: .languageDetection,
            outcome: detected ? .succeeded : .degraded,
            requestedEngine: engine.rawValue,
            effectiveEngine: engine.rawValue,
            reason: detected ? nil : .detectionInconclusive
        )
    }

    /// `VoiceActivityDetecting` cannot throw either: no regions means either
    /// silence or a failed detection, which are not distinguishable here —
    /// recorded as degraded because the stages downstream lose their
    /// segmentation input in both cases.
    private static func voiceActivityReport(
        engine: VADEngine,
        regions: [SpeechRegion]
    ) -> PipelineStageReport {
        PipelineStageReport(
            stage: .voiceActivityDetection,
            outcome: regions.isEmpty ? .degraded : .succeeded,
            requestedEngine: engine.rawValue,
            effectiveEngine: engine.rawValue,
            reason: regions.isEmpty ? .noInput : nil
        )
    }
}
