//
//  FluidAudioDiarizer.swift
//  Kurn
//
//  Optional diarization engine backed by FluidAudio's on-device offline
//  diarizer (Pyannote/WeSpeaker CoreML models, downloaded on first use).
//  Mirrors SpeakerDiarizer's contract: never throws out of `diarize(url:)` —
//  falls back to a single speaker turn on any failure, including a missing
//  model download.
//
//  This file only drives FluidAudio and reads its types into plain values.
//  Every decision about the result lives in tested code: labeling and
//  progress in KurnCore's `DiarizerSegmentLabeling`/`ChunkProgressSampler`,
//  the collapse rescue, smoothing, voiceprints and the time budget in
//  `DiarizationFinalization`. It is excluded from the coverage gate on that
//  basis (`Tools/coverage_scope.json`); new logic belongs in those types.
//

import AVFoundation
import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioDiarizer: Diarizing {
    // `OfflineDiarizerManager` isn't `Sendable`, and calling its `async` methods
    // from inside this actor makes the compiler treat each call as crossing an
    // isolation boundary. `manager` is a `let` never exposed outside this actor,
    // so there's no real aliasing risk — `nonisolated(unsafe)` matches the same
    // pattern already used for `LockScreenRecordingController.activity`.
    private nonisolated(unsafe) var manager = OfflineDiarizerManager(config: FluidAudioDiarizer.tunedConfig(speakerCount: 0))
    private var modelsReady = false
    /// Speaker count the current `manager` was built with. The manager bakes its
    /// config at init (it has no per-call config), so a change here forces a
    /// rebuild + re-prepare.
    private var currentSpeakerCount = 0
    /// First model preparation of a session also compiles the CoreML artifacts
    /// (and may finish a download), which is far slower than a warm load.
    private let prepareTimeout: TimeInterval = 300

    /// Override of `OfflineDiarizerConfig.default` for this app's audio.
    ///
    /// The VBx warm-start priors are left at the community-1 defaults
    /// (`Fa=0.07`, `Fb=0.8`) that FluidAudio benchmarks against. Earlier
    /// versions of this file raised them steeply to fight VBx collapsing every
    /// cluster into one speaker on far-field/single-mic audio; that traded one
    /// failure for another (a diffuse Dirichlet prior makes VBx keep the
    /// agglomerative init's cluster count, which is routinely dozens) and it
    /// was working around a lever that never actually engaged — see
    /// `speakerCount` below. Collapse is now handled after the fact by
    /// `SpeakerClusterRefiner`, so the clustering stage can stay on the
    /// upstream-tuned defaults.
    ///
    /// - Parameter speakerCount: when > 1, pins `clustering.numSpeakers`, which
    ///   makes the pipeline re-cluster the raw embeddings with KMeans into
    ///   exactly that many speakers. `0`/`1` leaves the count unconstrained.
    ///
    /// This deliberately sets `numSpeakers` rather than `minSpeakers`. FluidAudio
    /// decides whether to apply a speaker-count constraint by comparing the
    /// bounds against `VBxOutput.numClusters`, which it reports as the *input*
    /// agglomerative cluster count, not the number of components VBx kept. That
    /// count is large (tens) on any real meeting, so a `minSpeakers` floor of 2
    /// or 3 is always already satisfied and the KMeans re-cluster never runs —
    /// exactly the case it was meant to rescue. A maximum (which `numSpeakers`
    /// implies) is the only bound that trips, and it re-clusters to the
    /// requested count.
    ///
    /// `exposeChunkEmbeddings` is now on in **both** modes. It used to be gated
    /// on an unconstrained count, because the collapse rescue was its only
    /// consumer and that rescue can only run when the count is free. It has a
    /// second consumer now: the per-speaker voiceprints that keep a user-typed
    /// name attached to the right person across a re-transcription, which are
    /// just as necessary when the speaker count is pinned. The payload is ~1–2 MB
    /// per hour of audio and is transient — it never reaches disk.
    private static func tunedConfig(speakerCount: Int) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        if speakerCount > 1 {
            config.clustering.numSpeakers = speakerCount
        }
        config.exposeChunkEmbeddings = true
        return config
    }

    /// Rebuild `manager` if the requested speaker count differs from the one it
    /// was constructed with. Resets `modelsReady` so models re-prepare against
    /// the new config (cheap: weights are cached on disk, only recompiled).
    private func ensureManager(speakerCount: Int) {
        guard speakerCount != currentSpeakerCount else { return }
        manager = OfflineDiarizerManager(config: Self.tunedConfig(speakerCount: speakerCount))
        currentSpeakerCount = speakerCount
        modelsReady = false
    }

    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0, onDownloadFailure: nil)
    }

    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0, onDownloadFailure: onDownloadFailure)
    }

    /// - Parameter speakerCount: the exact number of speakers to force, or `0`
    ///   to let the pipeline decide (and let the collapse rescue run).
    /// - Parameter onDownloadFailure: reported only for a model preparation
    ///   failure (the one case where re-consenting/redownloading could help).
    ///   Passed per call, not stored on the actor, so concurrent transcriptions
    ///   of different recordings can't have their warning handlers cross over.
    func diarize(
        url: URL,
        speakerCount: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?
    ) async -> [SpeakerTurn] {
        await outcome(url: url, speakerCount: speakerCount, onDownloadFailure: onDownloadFailure).turns
    }

    /// The full result, including the voiceprints `Diarizing` has no room for.
    /// `TranscriptionService` calls this actor directly rather than through the
    /// protocol, so the richer return stays confined to the one engine that can
    /// produce it.
    func outcome(
        url: URL,
        speakerCount: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> DiarizationOutcome {
        ensureManager(speakerCount: speakerCount)
        if speakerCount > 1 {
            AppLog.transcription.atNotice.notice("FluidAudioDiarizer: speakerCount=\(speakerCount, privacy: .public) (pinned, KMeans re-cluster)")
        }
        if !modelsReady {
            let preparationStarted = Date()
            AppLog.transcription.atNotice.notice("FluidAudioDiarizer: preparing models file=\(url.lastPathComponent, privacy: .public) timeout=\(self.prepareTimeout, privacy: .public)s")
            do {
                try await withTimeout(seconds: prepareTimeout, timeoutError: Self.timeoutError) {
                    try await self.prepareModels()
                }
                modelsReady = true
                AppLog.transcription.atNotice.notice("FluidAudioDiarizer: models ready in \(Date().timeIntervalSince(preparationStarted), privacy: .public)s")
            } catch {
                AppLog.transcription.atError.error("FluidAudioDiarizer: model preparation failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                onDownloadFailure?(error.localizedDescription)
                return DiarizationOutcome(
                    turns: [Self.fallbackTurn(for: url)],
                    degradation: .modelPreparationFailed
                )
            }
        }
        onProgress?(0)
        let duration = Self.audioDuration(of: url)
        let timeout = Self.processTimeout(forAudioDuration: duration)
        AppLog.transcription.atNotice.notice("FluidAudioDiarizer: processing file=\(url.lastPathComponent, privacy: .public) audio=\(String(format: "%.1f", duration), privacy: .public)s timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
        do {
            let outcome = try await withTimeout(seconds: timeout, timeoutError: Self.timeoutError) {
                try await self.processAndMapTurns(url: url, onProgress: onProgress)
            }
            return DiarizationFinalization.nonEmpty(outcome, fallback: Self.fallbackTurn(for: url))
        } catch {
            // Not a download/consent problem (models are already prepared) —
            // log it, but don't route it through the download-failure banner,
            // which would mislead the user into re-consenting for no reason.
            AppLog.transcription.atError.error("FluidAudioDiarizer: processing failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return DiarizationOutcome(turns: [Self.fallbackTurn(for: url)], degradation: .engineFailed)
        }
    }

    /// Isolated so the non-`Sendable` `manager` never has to cross out of this
    /// actor — `withTimeout`'s race runs this as a child task, but the task
    /// only ever touches `self` (an actor, hence `Sendable`), never `manager`
    /// directly.
    private func prepareModels() async throws {
        try await manager.prepareModels()
    }

    /// Same isolation reasoning as `prepareModels()`, and also keeps
    /// FluidAudio's own result type from having to satisfy `Sendable` — only
    /// the already-`Sendable` `[SpeakerTurn]` needs to cross the boundary.
    private func processAndMapTurns(
        url: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutcome {
        let started = Date()
        let fileName = url.lastPathComponent
        let result = try await manager.process(url) { processed, total in
            let step = ChunkProgressSampler.step(
                processed: processed,
                total: total,
                elapsed: Date().timeIntervalSince(started)
            )
            if let fraction = step.fraction { onProgress?(fraction) }
            guard step.shouldLog else { return }
            let elapsed = Date().timeIntervalSince(started)
            if step.isFinished {
                AppLog.transcription.atInfo.info("FluidAudioDiarizer: audio pass 100% file=\(fileName, privacy: .public) chunks=\(total, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s; finalizing embeddings and clustering")
            } else {
                AppLog.transcription.atInfo.info("FluidAudioDiarizer: audio pass \(step.percent, privacy: .public)% file=\(fileName, privacy: .public) chunks=\(processed, privacy: .public)/\(total, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s eta≈\(String(format: "%.1f", step.estimatedRemaining), privacy: .public)s")
            }
        }
        let segments = result.segments.map {
            DiarizerSegment(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
        let distinct = DiarizerSegmentLabeling.distinctSpeakerCount(in: segments)
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: segments=\(segments.count, privacy: .public) uniqueSpeakerIds=\(distinct, privacy: .public)")

        let outcome = DiarizationFinalization.outcome(
            turns: DiarizerSegmentLabeling.turns(from: segments),
            distinctSpeakers: distinct,
            windows: Self.embeddingWindows(from: result.chunkEmbeddings)
        )
        onProgress?(1)
        return outcome
    }

    private static func embeddingWindows(from chunks: [ChunkEmbedding]?) -> [SpeakerEmbeddingWindow]? {
        guard let chunks, !chunks.isEmpty else { return nil }
        return chunks.map {
            SpeakerEmbeddingWindow(
                start: $0.startTimeSeconds,
                end: $0.endTimeSeconds,
                embedding: $0.embedding256
            )
        }
    }

    private static let timeoutError: @Sendable () -> Error = {
        AppError.modelDownloadFailed(
            NSLocalizedString("error.model_download_timeout", comment: "Model download/processing timed out")
        )
    }
}

#else

/// Built without the FluidAudio package linked: always falls back to a single
/// speaker turn so `TranscriptionService` keeps working until the package is added.
actor FluidAudioDiarizer: Diarizing {
    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0, onDownloadFailure: nil)
    }

    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0, onDownloadFailure: onDownloadFailure)
    }

    func diarize(
        url: URL,
        speakerCount: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?
    ) async -> [SpeakerTurn] {
        await outcome(url: url, speakerCount: speakerCount, onDownloadFailure: onDownloadFailure).turns
    }

    func outcome(
        url: URL,
        speakerCount: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> DiarizationOutcome {
        let message = NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        AppLog.transcription.atError.error("FluidAudioDiarizer: \(message, privacy: .public)")
        onDownloadFailure?(message)
        onProgress?(1)
        return DiarizationOutcome(turns: [Self.fallbackTurn(for: url)], degradation: .engineUnavailable)
    }
}

#endif

// MARK: - Shared helpers
//
// Outside the `#if canImport(FluidAudio)` split: both build configurations need
// the same fallback turn, and keeping one copy stops the two branches drifting
// apart. The processing budget lives in `DiarizationFinalization.swift`.

extension FluidAudioDiarizer {
    /// A single speaker turn spanning the whole clip, used whenever diarization
    /// can't produce real turns — covering the full duration (instead of a
    /// zero-length range) keeps downstream speaker-label lookups meaningful.
    fileprivate static func fallbackTurn(for url: URL) -> SpeakerTurn {
        SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, audioDuration(of: url)))
    }

    fileprivate static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
