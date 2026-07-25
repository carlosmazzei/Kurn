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
    /// `exposeChunkEmbeddings` is enabled only when the count is unconstrained,
    /// because that is the one mode where the collapse rescue can run; the extra
    /// payload is ~1–2 MB per hour of audio, so there is no reason to carry it
    /// when it can't be used.
    private static func tunedConfig(speakerCount: Int) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        if speakerCount > 1 {
            config.clustering.numSpeakers = speakerCount
        } else {
            config.exposeChunkEmbeddings = true
        }
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
        ensureManager(speakerCount: speakerCount)
        if speakerCount > 1 {
            AppLog.transcription.atNotice.notice("FluidAudioDiarizer: speakerCount=\(speakerCount, privacy: .public) (pinned, KMeans re-cluster)")
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
        let duration = Self.audioDuration(of: url)
        do {
            let turns = try await Self.withTimeout(seconds: Self.processTimeout(forAudioDuration: duration)) {
                try await self.processAndMapTurns(url: url)
            }
            return turns.isEmpty ? [Self.fallbackTurn(for: url)] : turns
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

        var turns = Self.turns(from: result.segments)
        if uniqueIDs <= 1, let windows = Self.embeddingWindows(from: result.chunkEmbeddings) {
            turns = Self.rescueCollapsedSpeakers(turns: turns, windows: windows)
        }
        let smoothed = SpeakerTurnSmoothing.smooth(turns)
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: smoothed turns \(turns.count, privacy: .public) -> \(smoothed.count, privacy: .public), speakers=\(Set(smoothed.map { $0.speakerLabel }).count, privacy: .public)")
        return smoothed
    }

    /// Re-cluster the per-window speaker embeddings that VBx collapsed and
    /// re-attribute the diarizer's own segment boundaries to the result. Keeps
    /// `turns` unchanged when the embeddings genuinely hold a single voice.
    private static func rescueCollapsedSpeakers(
        turns: [SpeakerTurn],
        windows: [SpeakerEmbeddingWindow]
    ) -> [SpeakerTurn] {
        guard let labels = SpeakerClusterRefiner.clusterLabels(for: windows) else {
            AppLog.transcription.atInfo.info("FluidAudioDiarizer: single cluster confirmed by re-clustering \(windows.count, privacy: .public) windows")
            return turns
        }
        let rescued = SpeakerClusterRefiner.reassign(turns: turns, windows: windows, labels: labels)
        let speakers = Set(rescued.map { $0.speakerLabel }).count
        AppLog.transcription.atNotice.notice("FluidAudioDiarizer: recovered \(speakers, privacy: .public) speakers from \(windows.count, privacy: .public) embedding windows after VBx collapse")
        return rescued
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
        SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, audioDuration(of: url)))
    }

    private static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Processing budget scaled to the recording.
    ///
    /// This used to be a flat 120s, which a one-hour meeting can exceed on an
    /// older device even when everything is working — and the timeout path
    /// falls back to a single whole-clip turn, so the symptom was every long
    /// recording silently coming back as one speaker. Diarization runs well
    /// under real time on the ANE, so half of the recording's duration is a
    /// generous budget; the floor keeps short clips from tripping on model
    /// warm-up and the ceiling still bounds a genuinely stuck run.
    static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(1800, max(180, duration * 0.5))
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
        let message = NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        AppLog.transcription.atError.error("FluidAudioDiarizer: \(message, privacy: .public)")
        onDownloadFailure?(message)
        return [Self.fallbackTurn(for: url)]
    }

    static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(1800, max(180, duration * 0.5))
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
