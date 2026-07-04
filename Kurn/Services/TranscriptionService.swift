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
    /// Durable-progress sink invoked after every completed chunk on the
    /// resumable engines. The receiver persists the checkpoint so an
    /// interrupted transcription can continue instead of starting over.
    typealias CheckpointHandler = @Sendable (TranscriptionCheckpoint) -> Void

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
    private let diarizationPreprocessor = DiarizationPreprocessor()
    private let vadCompactor = VADAudioCompactor()
    private let onDeviceChunker = AudioChunker()

    /// Transcribe one recording file and return diarized segments, driving each
    /// pipeline stage through the engine selected in `config`.
    /// - Parameters:
    ///   - checkpoint: progress persisted by an earlier interrupted run. The
    ///     deterministic pre-transcription stages re-run; the chunk loop then
    ///     skips already-transcribed chunks when the checkpoint still matches
    ///     the derived plan (engine, language, chunk count).
    ///   - onPhase: optional progress callback reporting the active stage.
    ///   - onCheckpoint: durable-progress sink, called after every chunk.
    func transcribe(
        fileURL: URL,
        fileName: String,
        language: MeetingLanguage,
        config: PipelineConfiguration,
        checkpoint: TranscriptionCheckpoint? = nil,
        onPhase: @escaping PhaseHandler = { _ in },
        onDiarizationWarning: DiarizationWarningHandler? = nil,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> Output {
        let started = Date()
        AppLog.transcription.atNotice.notice("transcribe: start file=\(fileName, privacy: .public) engine=\(config.transcription.rawValue, privacy: .public) language=\(language.rawValue, privacy: .public)")
        try await ResourceGuard.requireTranscriptionHeadroom()

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
            AppLog.transcription.atDebug.debug("transcribe: preprocessing done in \(Date().timeIntervalSince(preStart), privacy: .public)s")
        } catch let appError as AppError {
            if case .resourceUnavailable = appError { throw appError }
            cleanedURL = fileURL
            AppLog.transcription.atError.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original: \(appError.localizedDescription, privacy: .public)")
        } catch {
            try ResourceGuard.rethrowIfResourceFailure(error)
            cleanedURL = fileURL
            AppLog.transcription.atError.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original: \(error.localizedDescription, privacy: .public)")
        }
        defer {
            if cleanedURL != fileURL {
                let url = cleanedURL
                Task { await preprocessor.cleanup(url) }
            }
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
        if resolvedLanguage != language {
            AppLog.transcription.atInfo.info("transcribe: language refined \(language.rawValue, privacy: .public) -> \(resolvedLanguage.rawValue, privacy: .public)")
        }
        try await ResourceGuard.requireTranscriptionHeadroom()

        // 3. Detect speech regions with the selected VAD engine. They drive both
        // the heuristic diarizer's segmentation and the silence-gating of the
        // audio fed to transcription.
        onPhase(.detectingSpeech)
        let regions = await resolveVAD(config.vad).detectSpeech(url: cleanedURL)
        AppLog.transcription.atDebug.debug("transcribe: VAD (\(config.vad.rawValue, privacy: .public)) regions=\(regions.count, privacy: .public)")
        try await ResourceGuard.requireTranscriptionHeadroom()

        // 4. Transcription and diarization are independent. Cloud transcription
        // (Whisper) keeps almost nothing on-device, so overlap it with local
        // diarization for speed. On-device engines load a large model whose
        // inference activations, run alongside the diarizer's over a long
        // recording, push the process past its memory limit and get the app
        // jetsammed — so run those two stages sequentially.
        //
        // Transcription always reads the ASR-tuned cleaned copy selected above
        // (or the original when ASR cleanup is disabled). Diarization gets its
        // own independent input: when `diarizationPreprocessingEnabled` is on
        // (default), a dedicated `DiarizationPreprocessor` builds a WAV from
        // the *original* recording with minimal DSP (HP + spectral noise
        // reduction + global peak normalization), preserving the natural timbre
        // and relative loudness that speaker embeddings rely on. When off,
        // diarization uses the original recording directly; it never reuses the
        // ASR chain's AGC + compression + AAC re-encode output.
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
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
            async let speakerTurns = diarize(
                originalURL: fileURL,
                engine: config.diarization,
                diarizationPreprocessingEnabled: config.diarizationPreprocessingEnabled,
                regions: regions,
                minSpeakers: config.fluidAudioMinSpeakers,
                onWarning: onDiarizationWarning
            )
            raw = try await rawTranscript
            AppLog.transcription.atNotice.notice("transcribe: Whisper complete, spans=\(raw.spans.count, privacy: .public) — waiting for diarization")
            turns = try await speakerTurns
            AppLog.transcription.atNotice.notice("transcribe: diarization complete, turns=\(turns.count, privacy: .public)")
        } else {
            AppLog.transcription.atDebug.debug("transcribe: transcribing then diarizing (sequential, on-device)…")
            raw = try await transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                language: resolvedLanguage,
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
            turns = try await diarize(
                originalURL: fileURL,
                engine: config.diarization,
                diarizationPreprocessingEnabled: config.diarizationPreprocessingEnabled,
                regions: regions,
                minSpeakers: config.fluidAudioMinSpeakers,
                onWarning: onDiarizationWarning
            )
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        // Distinct speakers in the raw diarizer turns, BEFORE fusion. Comparing
        // this against the post-fusion `speakers=` count below isolates whether a
        // collapse happens in the diarizer or in fusion: if `turnSpeakers` is
        // already 1 the diarizer found one voice; if it's >1 but `speakers=` is 1
        // the fusion step is dropping them.
        let turnSpeakers = Set(turns.map { $0.speakerLabel })
        AppLog.transcription.atNotice.notice("transcribe: engine done in \(Date().timeIntervalSince(txStart), privacy: .public)s spans=\(raw.spans.count, privacy: .public) turns=\(turns.count, privacy: .public) turnSpeakers=\(turnSpeakers.count, privacy: .public) [\(turnSpeakers.sorted().joined(separator: ", "), privacy: .public)]")

        // 5. Fuse text spans with speaker turns into attributed segments.
        onPhase(.finalizing)
        try await ResourceGuard.requireTranscriptionHeadroom()
        let segments = TranscriptFusion.segments(
            spans: raw.spans,
            turns: turns,
            maxSegmentDuration: maxSegmentDuration
        )

        var labels: [String] = []
        for segment in segments where !labels.contains(segment.speakerLabel) {
            labels.append(segment.speakerLabel)
        }

        AppLog.transcription.atNotice.notice("transcribe: complete in \(Date().timeIntervalSince(started), privacy: .public)s segments=\(segments.count, privacy: .public) speakers=\(labels.count, privacy: .public) [\(labels.joined(separator: ", "), privacy: .public)]")
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
    ///
    /// The Whisper and Apple Speech engines run chunked and resumable: a
    /// matching `checkpoint` skips already-transcribed chunks and
    /// `onCheckpoint` persists progress after each one. Checkpoint spans live
    /// on the (possibly compacted) engine-input timeline — the same timeline a
    /// resume re-derives — and are remapped to the original timeline below,
    /// after the whole engine pass completes.
    private func transcribeGated(
        cleanedURL: URL,
        regions: [SpeechRegion],
        engine: TranscriptionEngine,
        language: MeetingLanguage,
        checkpoint: TranscriptionCheckpoint? = nil,
        onPhase: @escaping PhaseHandler,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> RawTranscript {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let compaction = (try? await vadCompactor.compact(url: cleanedURL, regions: regions)) ?? nil
        try await ResourceGuard.requireTranscriptionHeadroom()
        let target = compaction?.url ?? cleanedURL
        defer {
            if let url = compaction?.url { vadCompactor.cleanup(url) }
        }

        let compacted = compaction != nil
        let resume = checkpoint.flatMap { cp in
            cp.matches(engine: engine, language: language, compacted: compacted) ? cp.runnerProgress : nil
        }
        let checkpointSink: (@Sendable (ChunkedTranscriptionRunner.Progress) -> Void)?
        if let onCheckpoint {
            checkpointSink = { progress in
                onCheckpoint(
                    TranscriptionCheckpoint(engine: engine, language: language, compacted: compacted, progress: progress)
                )
            }
        } else {
            checkpointSink = nil
        }

        let raw: RawTranscript
        switch engine {
        case .whisperAPI:
            raw = try await whisperTranscriber.transcribeResumable(
                url: target,
                language: language,
                resume: resume,
                onChunkCompleted: checkpointSink,
                onProgress: { progress in onPhase(.transcribing(progress: progress)) }
            )
        case .appleSpeech:
            raw = try await transcribeOnDeviceChunked(
                url: target,
                language: language,
                resume: resume,
                onChunkCompleted: checkpointSink,
                onPhase: onPhase
            )
        case .fluidAudioParakeet:
            raw = try await resolveTranscriber(engine).transcribe(
                url: target,
                language: language,
                onProgress: { progress in onPhase(.transcribing(progress: progress)) }
            )
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        guard let map = compaction?.map else { return raw }

        // Remap compacted-timeline spans back to the original timeline.
        let spans = raw.spans.map { span -> TranscribedSpan in
            let start = VADAudioCompactor.remap(span.start, map: map)
            let end = VADAudioCompactor.remap(span.end, map: map)
            return TranscribedSpan(text: span.text, start: start, end: max(start, end), confidence: span.confidence)
        }
        return RawTranscript(spans: spans, language: raw.language)
    }

    /// Apple Speech over duration-based chunks instead of one recognition task
    /// for the whole file — a single `SFSpeechRecognitionTask` over hours of
    /// audio is unreliable, and per-chunk completion gives the checkpoint sink
    /// durable progress to persist. Intra-chunk progress from the recognizer's
    /// partial results is blended into the overall fraction.
    private func transcribeOnDeviceChunked(
        url: URL,
        language: MeetingLanguage,
        resume: ChunkedTranscriptionRunner.Progress?,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) -> Void)?,
        onPhase: @escaping PhaseHandler
    ) async throws -> RawTranscript {
        let chunks = try await onDeviceChunker.chunkByDuration(url: url)
        let total = chunks.count
        defer {
            let chunker = onDeviceChunker
            Task { await chunker.cleanup(chunks) }
        }

        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            resume: resume,
            transcribeChunk: { chunk, index in
                try await appleTranscriber.transcribe(
                    url: chunk.url,
                    language: language,
                    onProgress: { fraction in
                        let clamped = min(1, max(0, fraction))
                        onPhase(.transcribing(progress: (Double(index) + clamped) / Double(total)))
                    }
                )
            },
            onChunkCompleted: onChunkCompleted,
            onProgress: { progress in onPhase(.transcribing(progress: progress)) }
        )
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
    ///
    /// When `diarizationPreprocessingEnabled` is on, the original recording is
    /// passed through `DiarizationPreprocessor` to produce a minimally-cleaned
    /// WAV that both engines consume; otherwise both consume the original
    /// recording directly. The VAD `regions` are unchanged either way — they're
    /// timestamps on the absolute timeline, which the preprocessor preserves.
    private func diarize(
        originalURL: URL,
        engine: DiarizationEngine,
        diarizationPreprocessingEnabled: Bool,
        regions: [SpeechRegion],
        minSpeakers: Int,
        onWarning: DiarizationWarningHandler?
    ) async throws -> [SpeakerTurn] {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let diarURL: URL
        let cleanupURL: URL?
        if diarizationPreprocessingEnabled {
            do {
                diarURL = try await diarizationPreprocessor.process(url: originalURL)
                cleanupURL = diarURL
                AppLog.transcription.atInfo.info("diarize: using preprocessed input \(diarURL.lastPathComponent, privacy: .public)")
            } catch {
                try ResourceGuard.rethrowIfResourceFailure(error)
                AppLog.transcription.atError.error("diarize: preprocess failed, falling back to original: \(error.localizedDescription, privacy: .public)")
                diarURL = originalURL
                cleanupURL = nil
            }
        } else {
            diarURL = originalURL
            cleanupURL = nil
            AppLog.transcription.atDebug.debug("diarize: preprocessor disabled, using original input")
        }
        defer {
            if let url = cleanupURL {
                Task { [diarizationPreprocessor] in await diarizationPreprocessor.cleanup(url) }
            }
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        switch engine {
        case .heuristic:
            let turns = await heuristicDiarizer.diarize(url: diarURL, speechRegions: regions)
            try await ResourceGuard.requireTranscriptionHeadroom()
            return turns
        case .fluidAudio:
            let turns = await fluidAudioDiarizer.diarize(
                url: diarURL, minSpeakers: minSpeakers, onDownloadFailure: onWarning
            )
            try await ResourceGuard.requireTranscriptionHeadroom()
            return turns
        }
    }
}
