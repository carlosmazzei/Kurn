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
import KurnCore

/// What the neural diarizer produces beyond the turns themselves.
///
/// The voiceprints are the reason this type exists. The model computes a speaker
/// embedding per window and the diarizer used to drop every one of them on the
/// way out, which left `"Speaker 2"` — a label reassigned in order of first
/// appearance on every run — as the only identity a `Speaker` row could be keyed
/// on. Carrying the centroid out is what lets a name the user typed follow the
/// voice instead of the number.
///
/// Empty for the heuristic engine, which has no embeddings to give.
struct DiarizationOutcome: Sendable {
    var turns: [SpeakerTurn]
    /// Speaker label → L2-normalized mean embedding.
    var voiceprints: [String: [Float]]
    /// Why these turns are not what the requested engine was supposed to
    /// produce, or `nil` when they are. Carried out of the engine because a
    /// single whole-clip turn is indistinguishable from a genuine
    /// one-speaker meeting once it reaches fusion (H5 PR 11).
    var degradation: PipelineStageReason?

    init(
        turns: [SpeakerTurn],
        voiceprints: [String: [Float]] = [:],
        degradation: PipelineStageReason? = nil
    ) {
        self.turns = turns
        self.voiceprints = voiceprints
        self.degradation = degradation
    }
}

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
                try await Self.withTimeout(seconds: prepareTimeout) {
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
            let outcome = try await Self.withTimeout(seconds: timeout) {
                try await self.processAndMapTurns(url: url, onProgress: onProgress)
            }
            return outcome.turns.isEmpty
                ? DiarizationOutcome(turns: [Self.fallbackTurn(for: url)], degradation: .noInput)
                : outcome
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
            let safeTotal = max(1, total)
            let safeProcessed = min(max(0, processed), safeTotal)
            let percent = safeProcessed * 100 / safeTotal
            let previousPercent = max(0, safeProcessed - 1) * 100 / safeTotal
            if percent > previousPercent {
                onProgress?(Double(safeProcessed) / Double(safeTotal))
            }
            let crossedDecile = percent / 10 > previousPercent / 10
            guard safeProcessed == 1 || safeProcessed == safeTotal || crossedDecile else { return }

            let elapsed = Date().timeIntervalSince(started)
            let remaining = safeProcessed > 0
                ? elapsed * Double(safeTotal - safeProcessed) / Double(safeProcessed)
                : 0
            if safeProcessed == safeTotal {
                AppLog.transcription.atInfo.info("FluidAudioDiarizer: audio pass 100% file=\(fileName, privacy: .public) chunks=\(safeProcessed, privacy: .public)/\(safeTotal, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s; finalizing embeddings and clustering")
            } else {
                AppLog.transcription.atInfo.info("FluidAudioDiarizer: audio pass \(percent, privacy: .public)% file=\(fileName, privacy: .public) chunks=\(safeProcessed, privacy: .public)/\(safeTotal, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s eta≈\(String(format: "%.1f", remaining), privacy: .public)s")
            }
        }
        let uniqueIDs = Set(result.segments.map { $0.speakerId }).count
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: segments=\(result.segments.count, privacy: .public) uniqueSpeakerIds=\(uniqueIDs, privacy: .public)")

        var turns = Self.turns(from: result.segments)
        let windows = Self.embeddingWindows(from: result.chunkEmbeddings)
        if uniqueIDs <= 1, let windows {
            turns = Self.rescueCollapsedSpeakers(turns: turns, windows: windows)
        }
        let smoothed = SpeakerTurnSmoothing.smooth(turns)
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: smoothed turns \(turns.count, privacy: .public) -> \(smoothed.count, privacy: .public), speakers=\(Set(smoothed.map { $0.speakerLabel }).count, privacy: .public)")

        // After smoothing and any rescue, so a voiceprint describes the speaker
        // as finally reported rather than as first clustered.
        let voiceprints = windows.map {
            SpeakerVoiceprints.centroids(turns: smoothed, windows: $0)
        } ?? [:]
        if !voiceprints.isEmpty {
            AppLog.transcription.atInfo.info("FluidAudioDiarizer: voiceprints for \(voiceprints.count, privacy: .public) speaker(s)")
        }
        onProgress?(1)
        return DiarizationOutcome(turns: smoothed, voiceprints: voiceprints)
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
// the same fallback turn and the same processing budget, and keeping one copy
// stops the two branches drifting apart.

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
}
