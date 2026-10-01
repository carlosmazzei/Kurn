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
        /// What each stage actually did: requested versus effective engine and
        /// a typed outcome/reason, so a run that fell back is distinguishable
        /// from one that ran as asked (H5). Persisted beside the transcript by
        /// `TranscriptionCoordinator.saveTranscript`.
        var report = PipelineReport()
    }

    /// A completed engine pass plus the stage reports produced along the way
    /// (compaction and transcription), returned together because
    /// `transcribeGated` can run concurrently with diarization — its reports
    /// travel back as values instead of mutating shared state.
    struct GatedTranscription: Sendable {
        var raw: RawTranscript
        var stages: [PipelineStageReport]
    }

    /// Cap on a single fused segment's spoken duration before it's split.
    private let maxSegmentDuration: TimeInterval = TranscriptFusion.defaultMaxSegmentDuration

    /// Stage engines, resolved per configuration choice. `.live` holds the
    /// real engines, created once and shared across concurrent transcriptions;
    /// tests inject fakes per stage.
    let engines: PipelineEngineCatalog
    /// Live network path, read once up front so a cloud transcription the
    /// transfer policy is about to refuse fails before the local stages run.
    let network: any NetworkPathSnapshotProviding

    init(
        engines: PipelineEngineCatalog = .live,
        network: any NetworkPathSnapshotProviding = NetworkPathObserver.shared
    ) {
        self.engines = engines
        self.network = network
    }

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
        var reportBuilder = PipelineReportBuilder()
        TempFileCleaner.cleanupOrphanedTempFiles()
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let fileDuration = (try? await AVURLAsset(url: fileURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
        AppLog.transcription.atNotice.notice("transcribe: start file=\(fileName, privacy: .public) size=\(fileSize, privacy: .public) bytes duration=\(String(format: "%.1f", fileDuration), privacy: .public)s engine=\(config.transcription.rawValue, privacy: .public) language=\(language.rawValue, privacy: .public)")
        try await ResourceGuard.requireTranscriptionHeadroom()
        try validateModelTransferPolicy(config)
        try validateCloudUploadPolicy(config)

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

        // 1–3. Audio cleanup, language detection, and VAD, with the typed
        // report entry each of them produces — see
        // `TranscriptionServiceInputPreparation.swift`.
        let prepared = try await prepareInput(
            fileURL: fileURL,
            config: config,
            language: language,
            onPhase: onPhase
        )
        let cleanedURL = prepared.cleanedURL
        let resolvedLanguage = prepared.language
        let regions = prepared.regions
        reportBuilder.record(contentsOf: prepared.stages)
        let preprocessor = resolvePreprocessor(config.preprocessing)
        defer {
            // `defer` can't `await`, so the async temp-file cleanup is fired as a
            // detached step; `TempFileCleaner` sweeps anything left if it's lost.
            if cleanedURL != fileURL {
                let url = cleanedURL
                Task { await preprocessor.cleanup(url) }
            }
        }
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
            AppLog.transcription.atNotice.notice("transcribe: diarization falling back to \(diarizationEngine.rawValue, privacy: .public); requested=\(config.diarization.rawValue, privacy: .public)")
            let fallbackMessage = config.diarization == .transcriptionProviderNative
                ? NSLocalizedString(
                    "warning.diarization_requires_native_provider",
                    comment: "Speaker separation is using the basic engine because the transcription setup doesn't support native diarization"
                )
                : NSLocalizedString(
                    "warning.diarization_models_not_downloaded",
                    comment: "Speaker separation is using the basic engine"
                )
            onDiarizationWarning?(fallbackMessage)
        }

        onPhase(.transcribing(progress: nil))
        let txStart = Date()
        let (gated, diarization) = try await transcribeAndDiarize(
            fileURL: fileURL,
            cleanedURL: cleanedURL,
            regions: regions,
            config: config,
            diarizationEngine: diarizationEngine,
            resolvedLanguage: resolvedLanguage,
            sourceFileSize: Int64(fileSize),
            sourceDuration: fileDuration,
            sourceDigest: sourceDigest,
            checkpoint: checkpoint,
            onPhase: onPhase,
            onDiarizationWarning: onDiarizationWarning,
            onCheckpoint: onCheckpoint
        )
        try await ResourceGuard.requireTranscriptionHeadroom()
        let raw = gated.raw
        reportBuilder.record(contentsOf: gated.stages)
        reportBuilder.record(diarizationStageReport(
            requested: config.diarization,
            effective: diarizationEngine,
            outcome: diarization
        ))
        let turns = diarization.turns
        // Distinct speakers in the raw diarizer turns, BEFORE fusion. Comparing
        // this against the post-fusion `speakers=` count below isolates whether a
        // collapse happens in the diarizer or in fusion: if `turnSpeakers` is
        // already 1 the diarizer found one voice; if it's >1 but `speakers=` is 1
        // the fusion step is dropping them.
        let turnSpeakers = Set(turns.map { $0.speakerLabel })
        AppLog.transcription.atNotice.notice("transcribe: engine done in \(Date().timeIntervalSince(txStart), privacy: .public)s spans=\(raw.spans.count, privacy: .public) turns=\(turns.count, privacy: .public) turnSpeakers=\(turnSpeakers.count, privacy: .public) [\(turnSpeakers.sorted().joined(separator: ", "), privacy: .public)]")

        // 5. Fuse text spans with speaker turns into attributed segments.
        // Whitespace-only spans carry no content — a cloud model answers a
        // clip with no intelligible speech with `""` rather than nothing — and
        // fused into a segment they made the integrity gate reject the *whole*
        // transcription as `emptySegmentText`. Dropped here, before anything
        // counts them as input.
        let spans = raw.spans.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        onPhase(.finalizing)
        try await ResourceGuard.requireTranscriptionHeadroom()
        let segments = TranscriptFusion.segments(
            spans: spans,
            turns: turns,
            maxSegmentDuration: maxSegmentDuration
        )
        // Fusion is pure and cannot fail; losing every span here when the
        // engine produced some is the one outcome worth recording. The
        // integrity gate below (H5 PR 12) is what rejects such output instead
        // of storing it.
        reportBuilder.record(
            .fusion,
            segments.isEmpty && !spans.isEmpty ? .failed : .succeeded,
            reason: segments.isEmpty && !spans.isEmpty ? .noInput : nil
        )

        // 6. Optionally correct transcription errors via the opt-in LLM stage —
        // see `TranscriptionServiceCorrection.swift`.
        let correction = try await correctIfRequested(
            segments: segments,
            language: resolvedLanguage,
            config: config,
            onPhase: onPhase
        )
        let correctedSegments = correction.segments
        reportBuilder.record(correction.stage)

        // 7. Final integrity gate (H5 PR 12). Everything above — the engine,
        // fusion, correction — is pure and cannot throw, so nothing upstream
        // stops a structurally broken result from reaching the save path on
        // its own. Rejecting it here, before `Output` is ever returned, is
        // what keeps a bad run from being able to replace a still-valid
        // transcript: `TranscriptionCoordinator.saveTranscript` only deletes the
        // existing transcript after this function has already returned
        // successfully, so throwing here leaves it untouched.
        if let failure = TranscriptIntegrityGate.validate(
            segments: correctedSegments,
            sourceDuration: fileDuration,
            hadTranscribedInput: !spans.isEmpty
        ) {
            AppLog.transcription.atError.error("transcribe: integrity gate rejected output: \(failure.rawValue, privacy: .public)")
            throw AppError.transcriptIntegrityFailed(failure.rawValue)
        }

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
            turns: turns,
            report: reportBuilder.report
        )
    }

    /// Run the transcription and diarization stages, choosing between three
    /// shapes based on `diarizationEngine`/`config.transcription`: native
    /// diarization piggybacks entirely on the transcription call (no separate
    /// audio pass at all), cloud transcription overlaps with a separate local
    /// diarization pass for speed, and on-device transcription runs the two
    /// sequentially to stay under the memory limit — see the comment above
    /// this function's one call site in `transcribe` for why.
    // swiftlint:disable:next function_parameter_count
    private func transcribeAndDiarize(
        fileURL: URL,
        cleanedURL: URL,
        regions: [SpeechRegion],
        config: PipelineConfiguration,
        diarizationEngine: DiarizationEngine,
        resolvedLanguage: MeetingLanguage,
        sourceFileSize: Int64,
        sourceDuration: TimeInterval,
        sourceDigest: String?,
        checkpoint: TranscriptionCheckpoint?,
        onPhase: @escaping PhaseHandler,
        onDiarizationWarning: DiarizationWarningHandler?,
        onCheckpoint: CheckpointHandler?
    ) async throws -> (gated: GatedTranscription, diarization: DiarizationOutcome) {
        let diarizationProgress = DiarizationPhaseRelay(onPhase: onPhase)
        let gated: GatedTranscription
        let diarization: DiarizationOutcome
        if diarizationEngine == .transcriptionProviderNative {
            // Diarization is derived from the transcription provider's own
            // response, not a separate pass over a separately-cleaned audio
            // copy — there is nothing to run concurrently or sequentially
            // here beyond the transcription call itself.
            AppLog.transcription.atDebug.debug("transcribe: diarization derived from transcription provider's own response…")
            gated = try await transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                transcriptionProvider: config.transcriptionProvider,
                transcriptionModel: config.transcriptionModel,
                cloudTransfer: config.cloudTransfer,
                whisperCppModel: config.whisperCppModel,
                language: resolvedLanguage,
                sourceFileSize: sourceFileSize,
                sourceDuration: sourceDuration,
                sourceDigest: sourceDigest,
                preprocessing: config.preprocessing,
                vad: config.vad,
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
            diarization = Self.nativeDiarizationOutcome(from: gated.raw, sourceDuration: sourceDuration)
        } else if config.transcription.isCloudTranscription {
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
                sourceFileSize: sourceFileSize,
                sourceDuration: sourceDuration,
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
            gated = try await rawTranscript
            AppLog.transcription.atNotice.notice("transcribe: Whisper complete, spans=\(gated.raw.spans.count, privacy: .public) — waiting for diarization")
            diarizationProgress.reveal()
            diarization = try await speakerOutcome
            AppLog.transcription.atNotice.notice("transcribe: diarization complete, turns=\(diarization.turns.count, privacy: .public)")
        } else {
            AppLog.transcription.atDebug.debug("transcribe: transcribing then diarizing (sequential, on-device)…")
            gated = try await transcribeGated(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: config.transcription,
                transcriptionProvider: config.transcriptionProvider,
                transcriptionModel: config.transcriptionModel,
                cloudTransfer: config.cloudTransfer,
                whisperCppModel: config.whisperCppModel,
                language: resolvedLanguage,
                sourceFileSize: sourceFileSize,
                sourceDuration: sourceDuration,
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
        return (gated, diarization)
    }

    /// Build a `DiarizationOutcome` from the transcription provider's own
    /// response, for `.transcriptionProviderNative`. When the provider didn't
    /// return any speaker turns this time (a transient gap in its response,
    /// not a genuine one-speaker meeting), fall back to a single synthetic
    /// turn covering the whole recording — the same shape every other
    /// diarizer's own failure fallback produces — rather than leaving fusion
    /// with no speaker at all.
    private static func nativeDiarizationOutcome(from raw: RawTranscript, sourceDuration: TimeInterval) -> DiarizationOutcome {
        guard let turns = raw.speakerTurns, !turns.isEmpty else {
            return DiarizationOutcome(
                turns: [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, sourceDuration))],
                degradation: .syntheticSingleTurn
            )
        }
        return DiarizationOutcome(turns: turns)
    }

    /// Map a finished diarization pass to its stage report. Three different
    /// things can make the speaker layer not what was asked for, and they need
    /// to stay distinguishable: the selection stepping down without model
    /// consent, the engine falling back to one synthetic whole-clip turn, and
    /// an engine that returned nothing at all.
    private func diarizationStageReport(
        requested: DiarizationEngine,
        effective: DiarizationEngine,
        outcome: DiarizationOutcome
    ) -> PipelineStageReport {
        let reason: PipelineStageReason?
        if requested != effective {
            reason = .notConsented
        } else if let degradation = outcome.degradation {
            reason = degradation == .noInput ? .syntheticSingleTurn : degradation
        } else if outcome.turns.isEmpty {
            reason = .noInput
        } else {
            reason = nil
        }
        return PipelineStageReport(
            stage: .diarization,
            outcome: reason == nil ? .succeeded : .degraded,
            requestedEngine: requested.rawValue,
            effectiveEngine: effective.rawValue,
            reason: reason
        )
    }

    // MARK: - Per-stage engine selectors

    // Not `private` only so the extensions in
    // `TranscriptionServiceInputPreparation.swift` and
    // `TranscriptionServiceCorrection.swift` can reach them.

    func resolvePreprocessor(_ engine: PreprocessingEngine) -> any AudioPreprocessing {
        engines.preprocessor(engine)
    }

    func resolveLanguageDetector(_ engine: LanguageDetectionEngine) -> any LanguageDetecting {
        engines.languageDetector(engine)
    }

    func resolveVAD(_ engine: VADEngine) -> any VoiceActivityDetecting {
        engines.vad(engine)
    }

    func resolveCorrector(_ engine: CorrectionEngine) -> any TranscriptCorrecting {
        engines.corrector(engine)
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

    /// Cloud transcription uploads the whole recording, so it follows the
    /// large-transfer policy. Checked here, before cleanup, VAD and chunking,
    /// because otherwise a cellular or Low Data Mode path is only discovered
    /// when the first chunk is sent — minutes into a run the user watched
    /// "transcribing" the whole time. Only a path the policy positively
    /// refuses fails early; an unknown one is left to the upload itself.
    private func validateCloudUploadPolicy(_ config: PipelineConfiguration) throws {
        // Without upload consent nothing is sent, and the consent refusal
        // further down is the more useful error.
        guard config.transcription.isCloudTranscription, config.cloudTranscriptionConsented else { return }
        let snapshot = network.snapshot
        guard snapshot.isKnown, config.largeTransferPolicy.blocks(snapshot) else { return }
        AppLog.transcription.atNotice.notice("transcribe: cloud upload blocked by transfer policy expensive=\(snapshot.isExpensive, privacy: .public) constrained=\(snapshot.isConstrained, privacy: .public)")
        throw AppError.networkPolicyRestricted
    }
}
