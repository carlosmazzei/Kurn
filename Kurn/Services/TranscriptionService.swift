//
//  TranscriptionService.swift
//  Kurn
//
//  Orchestrates a full transcription: runs the chosen engine (on-device or
//  Whisper), runs heuristic diarization over the same audio, then fuses the two
//  into speaker-attributed `TranscriptSegment`s. Works in value types only so it
//  is decoupled from SwiftData and safe to call off the main actor.
//

import AVFoundation
import Foundation
import KurnCore

/// Thread-safe bridge between diarization's concurrent callbacks and the phase
/// shown by the UI. Cloud transcription and diarization start together, but the
/// UI must keep showing transcription until its result is complete. Progress is
/// accumulated meanwhile and revealed atomically once Whisper finishes.
final class DiarizationPhaseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latestProgress = 0.0
    private var isRevealed = false
    private let onPhase: TranscriptionService.PhaseHandler

    init(onPhase: @escaping TranscriptionService.PhaseHandler) {
        self.onPhase = onPhase
    }

    func update(_ progress: Double) {
        let phase: TranscriptionPhase? = lock.withLock {
            let clampedProgress = min(1, max(0, progress))
            guard clampedProgress > latestProgress else { return nil }
            latestProgress = clampedProgress
            return isRevealed ? .diarizing(progress: latestProgress) : nil
        }
        if let phase { onPhase(phase) }
    }

    func reveal() {
        let progress = lock.withLock {
            isRevealed = true
            return latestProgress
        }
        onPhase(.diarizing(progress: progress))
    }
}

struct TranscriptionService {

    /// Callback invoked as the pipeline advances through its stages. May be
    /// called from a background executor; the receiver is responsible for
    /// hopping to the main actor before touching UI state.
    typealias PhaseHandler = @Sendable (TranscriptionPhase) -> Void
    /// Reports a non-fatal diarization failure (e.g. a FluidAudio model
    /// download error). Transcription still succeeds with a fallback turn.
    typealias DiarizationWarningHandler = @Sendable (String) -> Void
    /// Durable-progress sink invoked after every completed chunk on the
    /// resumable engines, and awaited before the next chunk starts (H4): the
    /// receiver must actually persist the checkpoint before returning, and
    /// throw if that persistence fails, so a save failure stops the run
    /// rather than letting the pipeline continue past a chunk that was never
    /// made durable.
    typealias CheckpointHandler = @Sendable (TranscriptionCheckpoint) async throws -> Void

    struct Output: Sendable {
        var segments: [TranscriptSegment]
        var language: String
        /// Distinct speaker labels in first-appearance order.
        var speakerLabels: [String]
        /// Speaker label → voiceprint, when the engine that ran produces them.
        /// Empty for the heuristic diarizer, which has no embeddings — the
        /// caller must treat an absent voiceprint as "unknown identity", never
        /// as "different person".
        var speakerVoiceprints: [String: [Float]] = [:]
        /// The diarizer's own turns, before fusion moved any boundary to match
        /// an ASR span. `segments` above is what the rest of the app uses, but
        /// scoring DER against it blends diarizer error with ASR boundary
        /// placement and fusion policy — the wrong instrument for comparing
        /// diarizers. This is the raw signal that lets an evaluation harness
        /// score both and tell which stage a regression belongs to.
        var turns: [SpeakerTurn] = []
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
    private let whisperCppTranscriber = WhisperCppTranscriber()
    private let heuristicDiarizer = SpeakerDiarizer()
    private let fluidAudioDiarizer = FluidAudioDiarizer()
    private let sherpaOnnxDiarizer = SherpaOnnxDiarizer()
    private let diarizationPreprocessor = DiarizationPreprocessor()
    private let vadCompactor = VADAudioCompactor()
    private let noOpCorrector = NoOpTranscriptCorrector()
    private let llmCorrector = LLMTranscriptCorrector()

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
        TempFileCleaner.cleanupOrphanedTempFiles()
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let fileDuration = (try? await AVURLAsset(url: fileURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atNotice.notice("transcribe: start file=\(fileName, privacy: .public) size=\(fileSize, privacy: .public) bytes duration=\(String(format: "%.1f", fileDuration), privacy: .public)s engine=\(config.transcription.rawValue, privacy: .public) language=\(language.rawValue, privacy: .public)")
        try await ResourceGuard.requireTranscriptionHeadroom()
        try validateModelTransferPolicy(config)

        // H4 pipeline fingerprint: identity of the *source* recording, so a
        // checkpoint from an earlier run can only resume this exact file, not
        // one that happens to share a size or duration. Only computed when the
        // basic metadata above is itself sane — an unreadable or malformed file
        // never gets a digest, which is what makes it never match anything on
        // resume rather than accidentally matching another equally-unverified
        // run (see `TranscriptionPipelineFingerprint.==`).
        let sourceDigest: String? = (fileSize > 0 && fileDuration.isFinite && fileDuration > 0)
            ? try? PipelineDigest.sha256Hex(ofFileAt: fileURL)
            : nil

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
        } catch is CancellationError {
            throw CancellationError()
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
            // `defer` can't `await`, so the async temp-file cleanup is fired as a
            // detached step; `TempFileCleaner` sweeps anything left if it's lost.
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
        try Task.checkCancellation()
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
        // The diarizer that will actually run. `.fluidAudio` without consent
        // steps back to the heuristic rather than downloading a model the user
        // never asked for, or failing and returning one turn for the meeting.
        let diarizationEngine = config.effectiveDiarization
        if config.diarizationFellBack {
            AppLog.transcription.atNotice.notice("transcribe: diarization falling back to \(diarizationEngine.rawValue, privacy: .public); FluidAudio models are not consented to")
            onDiarizationWarning?(
                NSLocalizedString(
                    "warning.diarization_models_not_downloaded",
                    comment: "Speaker separation is using the basic engine"
                )
            )
        }

        onPhase(.transcribing(progress: nil))
        let txStart = Date()
        let raw: RawTranscript
        let diarization: DiarizationOutcome
        let diarizationProgress = DiarizationPhaseRelay(onPhase: onPhase)
        if config.transcription == .whisperAPI {
            AppLog.transcription.atDebug.debug("transcribe: transcribing + diarizing (concurrent)…")
            async let rawTranscript = transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                transcriptionProvider: config.transcriptionProvider,
                transcriptionModel: config.transcriptionModel,
                cloudTransfer: config.cloudTransfer,
                whisperCppModel: config.whisperCppModel,
                language: resolvedLanguage,
                sourceFileSize: Int64(fileSize),
                sourceDuration: fileDuration,
                sourceDigest: sourceDigest,
                preprocessing: config.preprocessing,
                vad: config.vad,
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
            async let speakerOutcome = diarize(
                originalURL: fileURL,
                engine: diarizationEngine,
                diarizationPreprocessingEnabled: config.diarizationPreprocessingEnabled,
                regions: regions,
                speakerCount: config.fluidAudioSpeakerCount,
                onWarning: onDiarizationWarning,
                onProgress: diarizationProgress.update
            )
            raw = try await rawTranscript
            AppLog.transcription.atNotice.notice("transcribe: Whisper complete, spans=\(raw.spans.count, privacy: .public) — waiting for diarization")
            diarizationProgress.reveal()
            diarization = try await speakerOutcome
            AppLog.transcription.atNotice.notice("transcribe: diarization complete, turns=\(diarization.turns.count, privacy: .public)")
        } else {
            AppLog.transcription.atDebug.debug("transcribe: transcribing then diarizing (sequential, on-device)…")
            raw = try await transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                transcriptionProvider: config.transcriptionProvider,
                transcriptionModel: config.transcriptionModel,
                cloudTransfer: config.cloudTransfer,
                whisperCppModel: config.whisperCppModel,
                language: resolvedLanguage,
                sourceFileSize: Int64(fileSize),
                sourceDuration: fileDuration,
                sourceDigest: sourceDigest,
                preprocessing: config.preprocessing,
                vad: config.vad,
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
            diarizationProgress.reveal()
            diarization = try await diarize(
                originalURL: fileURL,
                engine: diarizationEngine,
                diarizationPreprocessingEnabled: config.diarizationPreprocessingEnabled,
                regions: regions,
                speakerCount: config.fluidAudioSpeakerCount,
                onWarning: onDiarizationWarning,
                onProgress: diarizationProgress.update
            )
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        let turns = diarization.turns
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

        // 6. Optionally correct transcription errors (spelling, punctuation,
        // homophones, obvious ASR mistakes) via the opt-in LLM stage, on the
        // already-fused, speaker-attributed segments. `TranscriptCorrecting`
        // conformers never throw and always return `segments.count` segments in
        // order — on any failure this degrades to "no correction ran", never to
        // a failed transcription.
        let correctionEngine = config.effectiveCorrection
        if correctionEngine != .none {
            onPhase(.correcting(progress: nil))
        }
        let correctedSegments = await resolveCorrector(correctionEngine).correct(
            segments: segments,
            language: resolvedLanguage,
            provider: config.correctionProvider,
            model: config.correctionModel,
            onProgress: { progress in
                guard correctionEngine != .none else { return }
                onPhase(.correcting(progress: progress))
            }
        )

        var labels: [String] = []
        for segment in correctedSegments where !labels.contains(segment.speakerLabel) {
            labels.append(segment.speakerLabel)
        }
        // Fusion never invents a label, so a voiceprint for one that did not
        // survive belongs to a speaker with no text, and is dropped rather than
        // persisted against nothing.
        let voiceprints = diarization.voiceprints.filter { labels.contains($0.key) }

        AppLog.transcription.atNotice.notice("transcribe: complete in \(Date().timeIntervalSince(started), privacy: .public)s segments=\(correctedSegments.count, privacy: .public) speakers=\(labels.count, privacy: .public) [\(labels.joined(separator: ", "), privacy: .public)]")
        return Output(
            segments: correctedSegments,
            language: raw.language.isEmpty ? (resolvedLanguage.localeIdentifier ?? raw.language) : raw.language,
            speakerLabels: labels,
            speakerVoiceprints: voiceprints,
            turns: turns
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
        case .whisperCpp: return whisperCppTranscriber
        }
    }

    /// Map a `VADEngine` to its engine.
    private func resolveVAD(_ engine: VADEngine) -> any VoiceActivityDetecting {
        switch engine {
        case .energyThreshold: return energyVAD
        case .fluidAudio: return fluidAudioVAD
        }
    }

    /// Map a `CorrectionEngine` to its engine.
    private func resolveCorrector(_ engine: CorrectionEngine) -> any TranscriptCorrecting {
        switch engine {
        case .none: return noOpCorrector
        case .llm: return llmCorrector
        }
    }

    private func validateModelTransferPolicy(_ config: PipelineConfiguration) throws {
        let sets: [ModelSet?] = [
            config.transcription.requiredModelSet(whisperCppModel: config.whisperCppModel),
            config.languageDetection.requiredModelSet,
            config.vad.requiredModelSet,
            config.effectiveDiarization.requiredModelSet
        ]
        try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
            for: sets.compactMap { $0 },
            policy: config.largeTransferPolicy
        )
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
        transcriptionProvider: AIProvider = .openAI,
        transcriptionModel: String = "whisper-1",
        cloudTransfer: CloudTranscriptionTransfer = CloudTranscriptionTransfer(),
        whisperCppModel: WhisperCppModel = .default,
        language: MeetingLanguage,
        sourceFileSize: Int64 = 0,
        sourceDuration: TimeInterval = 0,
        sourceDigest: String? = nil,
        preprocessing: PreprocessingEngine = .standardDSP,
        vad: VADEngine = .energyThreshold,
        checkpoint: TranscriptionCheckpoint? = nil,
        onPhase: @escaping PhaseHandler,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> RawTranscript {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let compaction: CompactionResult?
        do {
            compaction = try await vadCompactor.compact(url: cleanedURL, regions: regions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ResourceGuard.rethrowIfResourceFailure(error)
            AppLog.transcription.atError.error("transcribe: VAD compaction failed: \(error.localizedDescription, privacy: .public)")
            compaction = nil
        }
        if let compaction {
            AppLog.transcription.atInfo.info("transcribe: compaction applied, target \(compaction.url.lastPathComponent, privacy: .public)")
        } else {
            AppLog.transcription.atInfo.info("transcribe: no compaction, using cleaned audio")
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        let target = compaction?.url ?? cleanedURL
        defer {
            if let url = compaction?.url { vadCompactor.cleanup(url) }
        }

        let compacted = compaction != nil
        // Where a chunk may be cut, on the timeline the engine will actually
        // see. Compaction rewrites that timeline, so the original speech regions
        // do not describe it — the compactor's own map does.
        let cutPoints = compaction.map { ChunkBoundary.cutPoints(inCompactedTimeline: $0.map) }
            ?? ChunkBoundary.cutPoints(betweenSpeechRegions: regions)
        // Identity of the engine's swappable back-end, so a checkpoint written
        // by one is never resumed by another: the cloud provider for
        // `.whisperAPI`, the weight file for `.whisperCpp` (resuming a
        // small-model run with the large model would splice two transcripts of
        // different quality). The remaining engines have no such axis.
        let checkpointProviderID: String?
        switch engine {
        case .whisperAPI: checkpointProviderID = transcriptionProvider.id
        case .whisperCpp: checkpointProviderID = "whispercpp:\(whisperCppModel.rawValue)"
        case .appleSpeech, .fluidAudioParakeet: checkpointProviderID = nil
        }
        // H4: the compaction map's own identity, not just "compaction ran" —
        // two runs can agree on VAD engine and still compact differently.
        let compactionDigest = compaction.map { PipelineDigest.sha256Hex(of: $0.map) }
        let fingerprint = TranscriptionPipelineFingerprint(
            sourceFileSize: sourceFileSize,
            sourceDuration: sourceDuration,
            sourceDigest: sourceDigest,
            preprocessing: preprocessing,
            vad: vad,
            language: language,
            engine: engine,
            providerID: checkpointProviderID,
            compacted: compacted,
            compactionDigest: compactionDigest
        )
        let resume = checkpoint.flatMap { cp -> ChunkedTranscriptionRunner.Progress? in
            guard cp.isStructurallyValid else {
                AppLog.transcription.atError.error("transcribe: checkpoint failed structural validation, starting over")
                return nil
            }
            if cp.matches(fingerprint) {
                AppLog.transcription.atNotice.notice("transcribe: checkpoint matches engine=\(cp.engineRaw, privacy: .public) lang=\(cp.languageRaw, privacy: .public) compacted=\(cp.compacted, privacy: .public) chunks=\(cp.totalChunks, privacy: .public)/\(cp.completedChunks, privacy: .public)")
                return cp.runnerProgress
            }
            AppLog.transcription.atNotice.notice("transcribe: checkpoint mismatch stored(engine=\(cp.engineRaw, privacy: .public) lang=\(cp.languageRaw, privacy: .public) compacted=\(cp.compacted, privacy: .public) provider=\(cp.providerID ?? "-", privacy: .public) totalChunks=\(cp.totalChunks, privacy: .public)) != current(engine=\(engine.rawValue, privacy: .public) lang=\(language.rawValue, privacy: .public) compacted=\(compacted, privacy: .public) provider=\(checkpointProviderID ?? "-", privacy: .public)), starting over")
            return nil
        }
        let checkpointSink: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)?
        if let onCheckpoint {
            checkpointSink = { progress in
                try await onCheckpoint(TranscriptionCheckpoint(fingerprint: fingerprint, progress: progress))
            }
        } else {
            checkpointSink = nil
        }

        let raw: RawTranscript
        let targetSize = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let targetDuration = (try? await AVURLAsset(url: target).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atNotice.notice("transcribe: engine input \(target.lastPathComponent, privacy: .public) size=\(targetSize, privacy: .public) bytes duration=\(String(format: "%.1f", targetDuration), privacy: .public)s compacted=\(compacted, privacy: .public)")
        switch engine {
        case .whisperAPI:
            guard cloudTransfer.consented else {
                throw AppError.permissionDenied(NSLocalizedString(
                    "error.cloud_transcription_consent_required",
                    comment: "Cloud transcription requires upload consent"
                ))
            }
            raw = try await whisperTranscriber.transcribeResumable(
                url: target,
                language: language,
                provider: transcriptionProvider,
                model: transcriptionModel,
                transferPolicy: cloudTransfer.policy,
                cutPoints: cutPoints,
                resume: resume,
                onChunkCompleted: checkpointSink,
                onProgress: { progress, completed, total in
                    onPhase(.transcribing(progress: progress, chunks: total > 0 ? ChunkProgress(completed: completed, total: total) : nil))
                }
            )
        case .appleSpeech:
            raw = try await appleTranscriber.transcribe(
                url: target,
                language: language,
                onProgress: { progress in
                    onPhase(.transcribing(progress: progress, chunks: nil))
                }
            )
        case .whisperCpp:
            raw = try await whisperCppTranscriber.transcribeResumable(
                url: target,
                language: language,
                model: whisperCppModel,
                cutPoints: cutPoints,
                resume: resume,
                onChunkCompleted: checkpointSink,
                onProgress: { progress, completed, total in
                    onPhase(.transcribing(progress: progress, chunks: total > 0 ? ChunkProgress(completed: completed, total: total) : nil))
                }
            )
        case .fluidAudioParakeet:
            raw = try await resolveTranscriber(engine).transcribe(
                url: target,
                language: language,
                onProgress: { progress in onPhase(.transcribing(progress: progress, chunks: nil)) }
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
        speakerCount: Int,
        onWarning: DiarizationWarningHandler?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutcome {
        let started = Date()
        let originalSize = (try? originalURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let originalDuration = (try? await AVURLAsset(url: originalURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atNotice.notice("diarize: start file=\(originalURL.lastPathComponent, privacy: .public) engine=\(engine.rawValue, privacy: .public) size=\(originalSize, privacy: .public) bytes duration=\(String(format: "%.1f", originalDuration), privacy: .public)s")
        onProgress(0)
        try await ResourceGuard.requireTranscriptionHeadroom()
        let diarURL: URL
        let cleanupURL: URL?
        if diarizationPreprocessingEnabled {
            AppLog.transcription.atInfo.info("diarize: preprocessing requested file=\(originalURL.lastPathComponent, privacy: .public); shared preprocessor may queue concurrent recordings")
            do {
                diarURL = try await diarizationPreprocessor.process(
                    url: originalURL,
                    onProgress: { onProgress(0.55 * $0) }
                )
                cleanupURL = diarURL
                AppLog.transcription.atInfo.info("diarize: using preprocessed input \(diarURL.lastPathComponent, privacy: .public)")
            } catch is CancellationError {
                AppLog.transcription.atNotice.notice("diarize: preprocessing cancelled file=\(originalURL.lastPathComponent, privacy: .public)")
                throw CancellationError()
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
        onProgress(0.55)
        defer {
            if let url = cleanupURL {
                Task { [diarizationPreprocessor] in await diarizationPreprocessor.cleanup(url) }
            }
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        try Task.checkCancellation()
        switch engine {
        case .heuristic:
            onProgress(0.65)
            let turns = await heuristicDiarizer.diarize(url: diarURL, speechRegions: regions)
            try await ResourceGuard.requireTranscriptionHeadroom()
            AppLog.transcription.atNotice.notice("diarize: complete in \(Date().timeIntervalSince(started), privacy: .public)s, turns=\(turns.count, privacy: .public)")
            onProgress(0.98)
            // No voiceprints: three scalars and one greedy clustering pass leave
            // nothing behind that could identify a voice again later.
            return DiarizationOutcome(turns: turns)
        case .fluidAudio:
            onProgress(0.60)
            let outcome = await fluidAudioDiarizer.outcome(
                url: diarURL,
                speakerCount: speakerCount,
                onDownloadFailure: onWarning,
                onProgress: { onProgress(0.60 + 0.36 * $0) }
            )
            try Task.checkCancellation()
            try await ResourceGuard.requireTranscriptionHeadroom()
            let speakers = Set(outcome.turns.map { $0.speakerLabel }).count
            AppLog.transcription.atNotice.notice("diarize: FluidAudio complete in \(Date().timeIntervalSince(started), privacy: .public)s, turns=\(outcome.turns.count, privacy: .public) speakers=\(speakers, privacy: .public) voiceprints=\(outcome.voiceprints.count, privacy: .public)")
            onProgress(0.98)
            return outcome
        case .sherpaOnnx:
            onProgress(0.60)
            let turns = await sherpaOnnxDiarizer.diarize(url: diarURL, speakerCount: speakerCount)
            try await ResourceGuard.requireTranscriptionHeadroom()
            AppLog.transcription.atNotice.notice("diarize: SherpaOnnx complete in \(Date().timeIntervalSince(started), privacy: .public)s, turns=\(turns.count, privacy: .public)")
            onProgress(0.98)
            // No voiceprints yet: sherpa-onnx's CAM++ embeddings aren't
            // surfaced through this engine's MVP — see `SherpaOnnxDiarizer`.
            return DiarizationOutcome(turns: turns)
        }
    }
}
