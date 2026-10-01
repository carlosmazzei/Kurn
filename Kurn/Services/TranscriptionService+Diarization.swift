//
//  TranscriptionService+Diarization.swift
//  Kurn
//
//  The diarization half of `TranscriptionService.transcribe`: the optional
//  diarization-specific cleanup pass and the call into the selected
//  diarizer, under its own resource reservation. Split out of
//  `TranscriptionService.swift` to keep it under SwiftLint's file-length
//  limit.
//

import AVFoundation
import Foundation
import KurnCore

extension TranscriptionService {

    /// Dispatch to the chosen diarization engine. Both engines satisfy
    /// `Diarizing` and never throw, so this always returns usable turns. The
    /// heuristic engine reuses the pipeline's VAD regions; FluidAudio diarization
    /// is end-to-end and ignores them.
    ///
    /// Each diarizer is a single shared actor reused across concurrent
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
    func diarize(
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
        // H8 PR 17: same reasoning as `transcribeGated`'s own reservation
        // above — a global budget across concurrent recordings, not a
        // replacement for this file's existing single-recording sequential/
        // concurrent branch.
        return try await withResourceReservation(.diarization(engine)) {
            try await diarizeAdmitted(
                originalURL: originalURL,
                engine: engine,
                diarizationPreprocessingEnabled: diarizationPreprocessingEnabled,
                regions: regions,
                speakerCount: speakerCount,
                onWarning: onWarning,
                onProgress: onProgress,
                started: started
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func diarizeAdmitted(
        originalURL: URL,
        engine: DiarizationEngine,
        diarizationPreprocessingEnabled: Bool,
        regions: [SpeechRegion],
        speakerCount: Int,
        onWarning: DiarizationWarningHandler?,
        onProgress: @escaping @Sendable (Double) -> Void,
        started: Date
    ) async throws -> DiarizationOutcome {
        let diarURL: URL
        let cleanupURL: URL?
        if diarizationPreprocessingEnabled {
            AppLog.transcription.atInfo.info("diarize: preprocessing requested file=\(originalURL.lastPathComponent, privacy: .public); shared preprocessor may queue concurrent recordings")
            do {
                diarURL = try await engines.diarizationPreprocessor.process(
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
                AppLog.transcription.atError.error("diarize: preprocess failed, falling back to original code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
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
                let preprocessor = engines.diarizationPreprocessor
                Task { await preprocessor.cleanup(url) }
            }
        }
        try await ResourceGuard.requireTranscriptionHeadroom()
        try Task.checkCancellation()
        onProgress(0.60)
        let outcome = await engines.diarizer(engine).diarize(PipelineDiarizationRequest(
            url: diarURL,
            regions: regions,
            speakerCount: speakerCount,
            onWarning: onWarning,
            onProgress: { onProgress(0.60 + 0.36 * $0) }
        ))
        try Task.checkCancellation()
        try await ResourceGuard.requireTranscriptionHeadroom()
        let speakers = Set(outcome.turns.map { $0.speakerLabel }).count
        AppLog.transcription.atNotice.notice("diarize: \(engine.rawValue, privacy: .public) complete in \(Date().timeIntervalSince(started), privacy: .public)s, turns=\(outcome.turns.count, privacy: .public) speakers=\(speakers, privacy: .public) voiceprints=\(outcome.voiceprints.count, privacy: .public)")
        onProgress(0.98)
        return outcome
    }
}
