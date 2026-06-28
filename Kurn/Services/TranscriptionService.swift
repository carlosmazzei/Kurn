//
//  TranscriptionService.swift
//  Kurn
//
//  Orchestrates a full transcription: runs the chosen engine (on-device or
//  Whisper), runs heuristic diarization over the same audio, then fuses the two
//  into speaker-attributed `TranscriptSegment`s. Works in value types only so it
//  is decoupled from SwiftData and safe to call off the main actor.
//

import Foundation

struct TranscriptionService {

    /// Callback invoked as the pipeline advances through its stages. May be
    /// called from a background executor; the receiver is responsible for
    /// hopping to the main actor before touching UI state.
    typealias PhaseHandler = @Sendable (TranscriptionPhase) -> Void
    /// Reports a non-fatal diarization failure (e.g. a FluidAudio model
    /// download error). Transcription still succeeds with a fallback turn.
    typealias DiarizationWarningHandler = @Sendable (String) -> Void

    struct Output: Sendable {
        var segments: [TranscriptSegment]
        var language: String
        /// Distinct speaker labels in first-appearance order.
        var speakerLabels: [String]
    }

    /// Cap on a single fused segment's spoken duration before it's split.
    private let maxSegmentDuration: TimeInterval = TranscriptFusion.defaultMaxSegmentDuration

    // Stage engines are created once and reused across concurrent
    // transcriptions; the per-stage selectors below map a configuration choice
    // to one of these existing instances rather than spinning up a new actor
    // per call. The non-Sendable audio resources stay isolated inside each actor.
    private let standardPreprocessor = AudioPreprocessor()
    private let passthroughPreprocessor = PassthroughPreprocessor()
    private let energyVAD = EnergyVAD()
    private let fluidAudioVAD = FluidAudioVAD()
    private let noOpLanguageDetector = NoOpLanguageDetector()
    private let fluidAudioLanguageDetector = FluidAudioLanguageDetector()
    private let appleTranscriber = OnDeviceTranscriber()
    private let fluidAudioTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperTranscriber()
    private let heuristicDiarizer = SpeakerDiarizer()
    private let fluidAudioDiarizer = FluidAudioDiarizer()
    private let vadCompactor = VADAudioCompactor()

    /// Transcribe one recording file and return diarized segments, driving each
    /// pipeline stage through the engine selected in `config`.
    /// - Parameter onPhase: optional progress callback reporting the active stage.
    func transcribe(
        fileURL: URL,
        fileName: String,
        language: MeetingLanguage,
        config: PipelineConfiguration,
        onPhase: @escaping PhaseHandler = { _ in },
        onDiarizationWarning: DiarizationWarningHandler? = nil
    ) async throws -> Output {
        let started = Date()
        AppLog.transcription.atNotice.notice("transcribe: start file=\(fileName, privacy: .public) engine=\(config.transcription.rawValue, privacy: .public) language=\(language.rawValue, privacy: .public)")

        // 1. Clean the audio (selected preprocessing engine) before
        // transcription/diarization. If cleanup fails for any reason we fall
        // back to the original so transcription never breaks.
        onPhase(.preprocessing)
        let preprocessor = resolvePreprocessor(config.preprocessing)
        AppLog.transcription.atDebug.debug("transcribe: preprocessing (\(config.preprocessing.rawValue, privacy: .public))…")
        let preStart = Date()
        let cleanedURL: URL
        do {
            cleanedURL = try await preprocessor.process(url: fileURL)
            AppLog.transcription.atDebug.debug("transcribe: preprocessing done in \(Date().timeIntervalSince(preStart), privacy: .public)s")
        } catch {
            cleanedURL = fileURL
            AppLog.transcription.atError.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original: \(error.localizedDescription, privacy: .public)")
        }
        defer {
            if cleanedURL != fileURL {
                let url = cleanedURL
                Task { await preprocessor.cleanup(url) }
            }
        }

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
        if resolvedLanguage != language {
            AppLog.transcription.atInfo.info("transcribe: language refined \(language.rawValue, privacy: .public) -> \(resolvedLanguage.rawValue, privacy: .public)")
        }

        // 3. Detect speech regions with the selected VAD engine. They drive both
        // the heuristic diarizer's segmentation and the silence-gating of the
        // audio fed to transcription.
        onPhase(.detectingSpeech)
        let regions = await resolveVAD(config.vad).detectSpeech(url: cleanedURL)
        AppLog.transcription.atDebug.debug("transcribe: VAD (\(config.vad.rawValue, privacy: .public)) regions=\(regions.count, privacy: .public)")

        // 4. Transcription and diarization both read the same file but are
        // independent. Cloud transcription (Whisper) keeps almost nothing
        // on-device, so overlap it with local diarization for speed. On-device
        // engines load a large model whose inference activations, run alongside
        // the diarizer's over a long recording, push the process past its memory
        // limit and get the app jetsammed — so run those two stages sequentially.
        onPhase(.transcribing(progress: nil))
        let txStart = Date()
        let raw: RawTranscript
        let turns: [SpeakerTurn]
        if config.transcription == .whisperAPI {
            AppLog.transcription.atDebug.debug("transcribe: transcribing + diarizing (concurrent)…")
            async let rawTranscript = transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                language: resolvedLanguage,
                onPhase: onPhase
            )
            async let speakerTurns = diarize(
                url: cleanedURL,
                engine: config.diarization,
                regions: regions,
                onWarning: onDiarizationWarning
            )
            raw = try await rawTranscript
            turns = await speakerTurns
        } else {
            AppLog.transcription.atDebug.debug("transcribe: transcribing then diarizing (sequential, on-device)…")
            raw = try await transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                language: resolvedLanguage,
                onPhase: onPhase
            )
            turns = await diarize(
                url: cleanedURL,
                engine: config.diarization,
                regions: regions,
                onWarning: onDiarizationWarning
            )
        }
        AppLog.transcription.atInfo.info("transcribe: engine done in \(Date().timeIntervalSince(txStart), privacy: .public)s spans=\(raw.spans.count, privacy: .public) turns=\(turns.count, privacy: .public)")

        // 5. Fuse text spans with speaker turns into attributed segments.
        onPhase(.finalizing)
        let segments = TranscriptFusion.segments(
            spans: raw.spans,
            turns: turns,
            maxSegmentDuration: maxSegmentDuration
        )

        var labels: [String] = []
        for segment in segments where !labels.contains(segment.speakerLabel) {
            labels.append(segment.speakerLabel)
        }

        AppLog.transcription.atNotice.notice("transcribe: complete in \(Date().timeIntervalSince(started), privacy: .public)s segments=\(segments.count, privacy: .public) speakers=\(labels.count, privacy: .public)")
        return Output(
            segments: segments,
            language: raw.language.isEmpty ? (resolvedLanguage.localeIdentifier ?? raw.language) : raw.language,
            speakerLabels: labels
        )
    }

    // MARK: - Per-stage engine selectors

    /// Map a `PreprocessingEngine` to its (already instantiated) engine.
    private func resolvePreprocessor(_ engine: PreprocessingEngine) -> any AudioPreprocessing {
        switch engine {
        case .standardDSP: return standardPreprocessor
        case .none: return passthroughPreprocessor
        }
    }

    /// Map a `LanguageDetectionEngine` to its engine.
    private func resolveLanguageDetector(_ engine: LanguageDetectionEngine) -> any LanguageDetecting {
        switch engine {
        case .byTranscriber: return noOpLanguageDetector
        case .fluidAudioLID: return fluidAudioLanguageDetector
        }
    }

    /// Map a `TranscriptionEngine` to its engine.
    private func resolveTranscriber(_ engine: TranscriptionEngine) -> any Transcribing {
        switch engine {
        case .appleSpeech: return appleTranscriber
        case .fluidAudioParakeet: return fluidAudioTranscriber
        case .whisperAPI: return whisperTranscriber
        }
    }

    /// Map a `VADEngine` to its engine.
    private func resolveVAD(_ engine: VADEngine) -> any VoiceActivityDetecting {
        switch engine {
        case .energyThreshold: return energyVAD
        case .fluidAudio: return fluidAudioVAD
        }
    }

    // MARK: - VAD-gated transcription

    /// Transcribe using the chosen engine, first removing silence via the VAD
    /// speech regions (so engines don't hallucinate over silence). Span
    /// timestamps are remapped from the compacted timeline back to the original
    /// so they line up with diarization. Falls back to the original audio when
    /// compaction isn't worthwhile.
    private func transcribeGated(
        cleanedURL: URL,
        regions: [SpeechRegion],
        engine: TranscriptionEngine,
        language: MeetingLanguage,
        onPhase: @escaping PhaseHandler
    ) async throws -> RawTranscript {
        let transcriber = resolveTranscriber(engine)
        let compaction = (try? await vadCompactor.compact(url: cleanedURL, regions: regions)) ?? nil
        let target = compaction?.url ?? cleanedURL
        defer {
            if let url = compaction?.url { vadCompactor.cleanup(url) }
        }

        let raw = try await transcriber.transcribe(
            url: target,
            language: language,
            onProgress: { progress in onPhase(.transcribing(progress: progress)) }
        )
        guard let map = compaction?.map else { return raw }

        // Remap compacted-timeline spans back to the original timeline.
        let spans = raw.spans.map { span -> TranscribedSpan in
            let start = VADAudioCompactor.remap(span.start, map: map)
            let end = VADAudioCompactor.remap(span.end, map: map)
            return TranscribedSpan(text: span.text, start: start, end: max(start, end), confidence: span.confidence)
        }
        return RawTranscript(spans: spans, language: raw.language)
    }

    /// Dispatch to the chosen diarization engine. Both engines satisfy
    /// `Diarizing` and never throw, so this always returns usable turns. The
    /// heuristic engine reuses the pipeline's VAD regions; FluidAudio diarization
    /// is end-to-end and ignores them.
    ///
    /// `fluidAudioDiarizer` is a single shared actor reused across concurrent
    /// transcriptions (different recordings can transcribe at once), so the
    /// warning handler is passed as a call argument rather than set on shared
    /// actor state beforehand — that would let one call's handler leak into
    /// another's result at the actor's next suspension point.
    private func diarize(
        url: URL,
        engine: DiarizationEngine,
        regions: [SpeechRegion],
        onWarning: DiarizationWarningHandler?
    ) async -> [SpeakerTurn] {
        switch engine {
        case .heuristic:
            return await heuristicDiarizer.diarize(url: url, speechRegions: regions)
        case .fluidAudio:
            return await fluidAudioDiarizer.diarize(url: url, onDownloadFailure: onWarning)
        }
    }
}
