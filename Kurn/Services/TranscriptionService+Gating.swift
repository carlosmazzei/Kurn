//
//  TranscriptionService+Gating.swift
//  Kurn
//
//  The transcription half of `TranscriptionService.transcribe`: VAD
//  compaction, the checkpoint fingerprint and resume decision, the engine
//  call, and remapping the result back onto the original timeline. Split out
//  of `TranscriptionService.swift` to keep it under SwiftLint's file-length
//  limit.
//

import AVFoundation
import Foundation
import KurnCore

extension TranscriptionService {

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
    func transcribeGated(
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
    ) async throws -> GatedTranscription {
        try await ResourceGuard.requireTranscriptionHeadroom()
        // H8 PR 17: a global weight budget so two concurrent transcriptions
        // (different recordings) picking the same heavy on-device engine
        // can't both pass this preflight and then both hold that engine's
        // inference activations in memory at once — the cross-recording
        // analogue of why this file already never runs one recording's own
        // on-device ASR concurrently with its diarizer.
        return try await withResourceReservation(.transcription(engine)) {
            try await transcribeGatedAdmitted(
                cleanedURL: cleanedURL,
                regions: regions,
                engine: engine,
                transcriptionProvider: transcriptionProvider,
                transcriptionModel: transcriptionModel,
                cloudTransfer: cloudTransfer,
                whisperCppModel: whisperCppModel,
                language: language,
                sourceFileSize: sourceFileSize,
                sourceDuration: sourceDuration,
                sourceDigest: sourceDigest,
                preprocessing: preprocessing,
                vad: vad,
                checkpoint: checkpoint,
                onPhase: onPhase,
                onCheckpoint: onCheckpoint
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func transcribeGatedAdmitted(
        cleanedURL: URL,
        regions: [SpeechRegion],
        engine: TranscriptionEngine,
        transcriptionProvider: AIProvider,
        transcriptionModel: String,
        cloudTransfer: CloudTranscriptionTransfer,
        whisperCppModel: WhisperCppModel,
        language: MeetingLanguage,
        sourceFileSize: Int64,
        sourceDuration: TimeInterval,
        sourceDigest: String?,
        preprocessing: PreprocessingEngine,
        vad: VADEngine,
        checkpoint: TranscriptionCheckpoint?,
        onPhase: @escaping PhaseHandler,
        onCheckpoint: CheckpointHandler?
    ) async throws -> GatedTranscription {
        var stages: [PipelineStageReport] = []
        let compaction: CompactionResult?
        do {
            compaction = try await engines.compactor.compact(url: cleanedURL, regions: regions)
            // A `nil` result is the compactor declining (nothing worth
            // removing), which is not a failure and must not read as one.
            stages.append(PipelineStageReport(
                stage: .compaction,
                outcome: compaction == nil ? .skipped : .succeeded,
                reason: compaction == nil ? .noInput : nil
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ResourceGuard.rethrowIfResourceFailure(error)
            AppLog.transcription.atError.error("transcribe: VAD compaction failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            compaction = nil
            stages.append(PipelineStageReport(
                stage: .compaction,
                outcome: .degraded,
                reason: .engineFailed
            ))
        }
        if let compaction {
            AppLog.transcription.atInfo.info("transcribe: compaction applied, target \(compaction.url.lastPathComponent, privacy: .public)")
        } else {
            AppLog.transcription.atInfo.info("transcribe: no compaction, using cleaned audio")
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        let target = compaction?.url ?? cleanedURL
        defer {
            if let url = compaction?.url { engines.compactor.cleanup(url) }
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
        if engine.isCloudTranscription, !cloudTransfer.consented {
            throw AppError.permissionDenied(NSLocalizedString(
                "error.cloud_transcription_consent_required",
                comment: "Cloud transcription requires upload consent"
            ))
        }
        raw = try await engines.transcriber(engine).transcribe(EngineTranscriptionRequest(
            url: target,
            language: language,
            provider: transcriptionProvider,
            model: transcriptionModel,
            transferPolicy: cloudTransfer.policy,
            whisperCppModel: whisperCppModel,
            cutPoints: cutPoints,
            resume: resume,
            onChunkCompleted: checkpointSink,
            onProgress: { progress, chunks in
                onPhase(.transcribing(progress: progress, chunks: chunks))
            }
        ))
        try await ResourceGuard.requireTranscriptionHeadroom()
        // The engine either produced spans or threw; no spans at all from a
        // clip the VAD found speech in is the one silent-failure shape left.
        stages.append(PipelineStageReport(
            stage: .transcription,
            outcome: raw.spans.isEmpty && !regions.isEmpty ? .degraded : .succeeded,
            requestedEngine: engine.rawValue,
            effectiveEngine: engine.rawValue,
            reason: raw.spans.isEmpty && !regions.isEmpty ? .noInput : nil
        ))
        guard let map = compaction?.map else { return GatedTranscription(raw: raw, stages: stages) }

        // Remap compacted-timeline spans back to the original timeline — and
        // the provider's own speaker turns with them. Rebuilding the transcript
        // from spans alone dropped `speakerTurns`, so whenever compaction ran,
        // `.transcriptionProviderNative` fell back to one synthetic speaker
        // (measured on AMI with ElevenLabs: 64% raw DER instead of ~39%).
        let spans = raw.spans.map { span -> TranscribedSpan in
            let start = VADAudioCompactor.remap(span.start, map: map)
            let end = VADAudioCompactor.remap(span.end, map: map)
            return TranscribedSpan(text: span.text, start: start, end: max(start, end), confidence: span.confidence)
        }
        let speakerTurns = raw.speakerTurns?.map { turn -> SpeakerTurn in
            let start = VADAudioCompactor.remap(turn.start, map: map)
            let end = VADAudioCompactor.remap(turn.end, map: map)
            return SpeakerTurn(speakerLabel: turn.speakerLabel, start: start, end: max(start, end))
        }
        return GatedTranscription(
            raw: RawTranscript(spans: spans, language: raw.language, speakerTurns: speakerTurns),
            stages: stages
        )
    }
}
