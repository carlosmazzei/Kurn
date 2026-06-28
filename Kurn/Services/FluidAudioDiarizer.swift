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

import AVFoundation
import Foundation

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioDiarizer: Diarizing {
    // `OfflineDiarizerManager` isn't `Sendable`, and calling its `async` methods
    // from inside this actor makes the compiler treat each call as crossing an
    // isolation boundary. `manager` is a `let` never exposed outside this actor,
    // so there's no real aliasing risk — `nonisolated(unsafe)` matches the same
    // pattern already used for `LockScreenRecordingController.activity`.
    private nonisolated(unsafe) var manager = OfflineDiarizerManager(config: FluidAudioDiarizer.tunedConfig(minSpeakers: 0))
    private var modelsReady = false
    /// Speaker floor the current `manager` was built with. The manager bakes its
    /// config at init (it has no per-call config), so a change here forces a
    /// rebuild + re-prepare.
    private var currentMinSpeakers = 0
    private let prepareTimeout: TimeInterval = 60
    private let processTimeout: TimeInterval = 120

    /// Override of `OfflineDiarizerConfig.default` that swaps the VBx warm-start
    /// priors. The community defaults (Fa=0.07, Fb=0.8) consistently collapse
    /// multi-speaker AHC results into a single cluster on our recordings (the
    /// VBx mixture weights go to ~1e-20 for everything but one), even when
    /// segmentation and AHC both clearly find multiple speakers. The values
    /// here lift `Fa` above the BUT-VBx literature defaults (DIHARD/AMI): Fa=0.6
    /// gives the acoustic likelihood even more weight (so subtle x-vector
    /// differences aren't flattened away), and Fb=11 makes the Dirichlet prior
    /// far less concentrated so VBx preserves the cluster count it was given
    /// instead of collapsing to one.
    ///
    /// NOTE on what is *not* tunable here: FluidAudio's offline VBx is a
    /// variational-Bayes Dirichlet GMM, not the Brno HMM-VBx — there is no
    /// `loop_p`/self-loop/transition term to lower. The init smoothing that
    /// could keep the other components alive is hardcoded (`initSmoothing: 7.0`
    /// in `VBxClustering`), not in the public config. And the AHC init is not
    /// the bottleneck: it already yields ~59 clusters; VBx collapses *those* to
    /// one. So `Fa` is the only auto-side lever, and clustering-side tuning can
    /// only help when the *embeddings* are discriminative. On heavily-processed
    /// far-field audio they collapse into one blob and no Fa/Fb/threshold value
    /// recovers the speakers (feeding the original un-cleaned recording was tried
    /// and made no difference). When that happens, either set `minSpeakers`
    /// (forces a KMeans re-cluster, escaping the collapse) or use the heuristic
    /// `SpeakerDiarizer` (pitch/timbre based), which the user can select.
    ///
    /// - Parameter minSpeakers: when > 1, sets `clustering.minSpeakers`, which
    ///   makes the pipeline re-cluster with KMeans to at least that many speakers
    ///   whenever VBx collapses below it (which it does on far-field audio). When
    ///   0/1 the diarizer auto-detects with no floor.
    private static func tunedConfig(minSpeakers: Int) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.clustering.warmStartFa = 0.6
        config.clustering.warmStartFb = 11
        if minSpeakers > 1 {
            config.clustering.minSpeakers = minSpeakers
        }
        return config
    }

    /// Rebuild `manager` if the requested speaker floor differs from the one it
    /// was constructed with. Resets `modelsReady` so models re-prepare against
    /// the new config (cheap: weights are cached on disk, only recompiled).
    private func ensureManager(minSpeakers: Int) {
        guard minSpeakers != currentMinSpeakers else { return }
        manager = OfflineDiarizerManager(config: Self.tunedConfig(minSpeakers: minSpeakers))
        currentMinSpeakers = minSpeakers
        modelsReady = false
    }

    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, minSpeakers: 0, onDownloadFailure: nil)
    }

    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        await diarize(url: url, minSpeakers: 0, onDownloadFailure: onDownloadFailure)
    }

    /// - Parameter onDownloadFailure: reported only for a model preparation
    ///   failure (the one case where re-consenting/redownloading could help).
    ///   Passed per call, not stored on the actor, so concurrent transcriptions
    ///   of different recordings can't have their warning handlers cross over.
    func diarize(
        url: URL,
        minSpeakers: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?
    ) async -> [SpeakerTurn] {
        ensureManager(minSpeakers: minSpeakers)
        if minSpeakers > 1 {
            AppLog.transcription.atNotice.notice("FluidAudioDiarizer: minSpeakers=\(minSpeakers, privacy: .public) (forced KMeans re-cluster on VBx collapse)")
        }
        if !modelsReady {
            do {
                try await Self.withTimeout(seconds: prepareTimeout) {
                    try await self.prepareModels()
                }
                modelsReady = true
            } catch {
                AppLog.transcription.atError.error("FluidAudioDiarizer: model preparation failed: \(error.localizedDescription, privacy: .public)")
                onDownloadFailure?(error.localizedDescription)
                return [Self.fallbackTurn(for: url)]
            }
        }
        do {
            return try await Self.withTimeout(seconds: processTimeout) {
                try await self.processAndMapTurns(url: url)
            }
        } catch {
            // Not a download/consent problem (models are already prepared) —
            // log it, but don't route it through the download-failure banner,
            // which would mislead the user into re-consenting for no reason.
            AppLog.transcription.atError.error("FluidAudioDiarizer: processing failed: \(error.localizedDescription, privacy: .public)")
            return [Self.fallbackTurn(for: url)]
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
    private func processAndMapTurns(url: URL) async throws -> [SpeakerTurn] {
        let result = try await manager.process(url)
        let uniqueIDs = Set(result.segments.map { $0.speakerId }).count
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: segments=\(result.segments.count, privacy: .public) uniqueSpeakerIds=\(uniqueIDs, privacy: .public)")
        return Self.turns(from: result.segments)
    }

    /// Map FluidAudio's `speakerId` strings to the same "Speaker N" (1-indexed,
    /// first-appearance order) labels the heuristic engine produces.
    private static func turns(from segments: [TimedSpeakerSegment]) -> [SpeakerTurn] {
        let ordered = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var labelByID: [String: String] = [:]
        var turns: [SpeakerTurn] = []
        for segment in ordered {
            let label = labelByID[segment.speakerId] ?? {
                let next = "Speaker \(labelByID.count + 1)"
                labelByID[segment.speakerId] = next
                return next
            }()
            turns.append(
                SpeakerTurn(
                    speakerLabel: label,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds)
                )
            )
        }
        return turns
    }

    /// A single speaker turn spanning the whole clip, used whenever diarization
    /// can't produce real turns — covering the full duration (instead of a
    /// zero-length range) keeps downstream speaker-label lookups meaningful.
    private static func fallbackTurn(for url: URL) -> SpeakerTurn {
        let duration: TimeInterval
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else {
            duration = 0
        }
        return SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, duration))
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppError.modelDownloadFailed(
                    NSLocalizedString("error.model_download_timeout", comment: "Model download/processing timed out")
                )
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

#else

/// Built without the FluidAudio package linked: always falls back to a single
/// speaker turn so `TranscriptionService` keeps working until the package is added.
actor FluidAudioDiarizer: Diarizing {
    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, minSpeakers: 0, onDownloadFailure: nil)
    }

    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        await diarize(url: url, minSpeakers: 0, onDownloadFailure: onDownloadFailure)
    }

    func diarize(
        url: URL,
        minSpeakers: Int,
        onDownloadFailure: (@Sendable (String) -> Void)?
    ) async -> [SpeakerTurn] {
        let message = NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        AppLog.transcription.atError.error("FluidAudioDiarizer: \(message, privacy: .public)")
        onDownloadFailure?(message)
        return [Self.fallbackTurn(for: url)]
    }

    private static func fallbackTurn(for url: URL) -> SpeakerTurn {
        let duration: TimeInterval
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else {
            duration = 0
        }
        return SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, duration))
    }
}

#endif
