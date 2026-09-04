//
//  SherpaOnnxDiarizer.swift
//  Kurn
//
//  Optional third diarization engine (sherpa-onnx, segmentation-first:
//  pyannote/segmentation-3.0 decides who is speaking in short windows, then
//  a 3D-Speaker CAM++ embedding clusters those windows into speakers).
//
//  Offered as an alternative to `FluidAudioDiarizer`, not a replacement: that
//  engine's known failure is its VBx clustering step collapsing every
//  speaker into one on far-field/single-mic audio. This engine attacks the
//  same problem from the other end — segment first, cluster after — which
//  fails differently, not necessarily less. It runs on CPU only via ONNX
//  Runtime (no ANE acceleration on iOS), a deliberate trade of speed for a
//  structurally different collapse mode. See `docs/roadmap.md`, item D4.
//
//  Mirrors `FluidAudioDiarizer`'s contract: never throws out of
//  `diarize(url:)` — falls back to a single speaker turn on any failure,
//  including missing models.
//
//  The real implementation below is guarded by `SHERPA_ONNX_ENABLED` rather
//  than `#if canImport(...)`: sherpa-onnx ships a C API with no importable
//  Clang module of its own (its SPM product is literally named "sherpa-onnx",
//  not a valid module identifier), unlike FluidAudio/whisper.cpp, which are
//  `import`ed directly. It reaches Swift through
//  `Kurn/Services/SherpaOnnx/SherpaOnnx-Bridging-Header.h`
//  (`SWIFT_OBJC_BRIDGING_HEADER` on the `Kurn` target) plus that compilation
//  condition (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, Debug and Release) —
//  both verified locally in Xcode and set on the `Kurn` target only, not
//  `KurnTests`'s, matching the existing "KurnTests doesn't link the optional
//  package" convention documented on `WhisperCppModelDownloader`. Confirmed
//  reachable in CI by the 2026-08-27 pipeline-eval dispatch
//  (`docs/pipeline-evaluation.md`) — the log shows real per-item processing
//  times, not the `#else` stub's instant fallback.
//

import AVFoundation
import Foundation
import KurnCore

#if SHERPA_ONNX_ENABLED

actor SherpaOnnxDiarizer: Diarizing {
    private var wrapper: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    private var currentSpeakerCount = 0
    private var modelsReady = false

    /// Proves the two downloaded model files actually load, without keeping
    /// the pipeline around — used by `SherpaOnnxModelDownloader` right after
    /// install (H7 PR 16). Unlike `diarize(url:)`, this throws: a fresh
    /// install that fails to load is a download failure, not something to
    /// silently degrade into a one-speaker fallback the first time real
    /// diarization runs. Constructing the wrapper is a blocking C call (CPU
    /// ONNX Runtime, loading two graphs), so this runs detached.
    static func verifyModelsLoad() async throws {
        // H8 PR 17: same global weight budget as a real diarization run's
        // load — see `WhisperCppTranscriber.verifyModelLoads(at:)`'s own
        // comment for why.
        try await withResourceReservation(.modelLoading) {
            try await Task.detached(priority: .utility) {
                guard SherpaOnnxOfflineSpeakerDiarizationWrapper(
                    segmentationModelPath: SherpaOnnxModelDownloader.segmentationModelURL.path,
                    embeddingModelPath: SherpaOnnxModelDownloader.embeddingModelURL.path,
                    numSpeakers: 1,
                    numThreads: 1
                ) != nil else {
                    throw AppError.modelDownloadFailed("sherpa-onnx models failed to load — the downloaded files may be corrupt")
                }
            }.value
        }
    }

    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0)
    }

    /// - Parameter speakerCount: the exact number of speakers to force, or
    ///   `0` to let clustering decide.
    func diarize(url: URL, speakerCount: Int) async -> [SpeakerTurn] {
        ensureWrapper(speakerCount: speakerCount)
        guard let wrapper else {
            AppLog.transcription.atError.error("SherpaOnnxDiarizer: models unavailable, falling back to one turn")
            return [Self.fallbackTurn(for: url)]
        }

        let duration = Self.audioDuration(of: url)
        let budget = Self.processTimeout(forAudioDuration: duration)
        AppLog.transcription.atNotice.notice("SherpaOnnxDiarizer: processing file=\(url.lastPathComponent, privacy: .public) audio=\(String(format: "%.1f", duration), privacy: .public)s budget=\(String(format: "%.1f", budget), privacy: .public)s")
        guard !Task.isCancelled else {
            AppLog.transcription.atNotice.notice("SherpaOnnxDiarizer: cancelled before starting")
            return [Self.fallbackTurn(for: url)]
        }
        do {
            // H8 PR 18: this used to race `processSynchronously` against a
            // sleeping timer in a `TaskGroup` and call it a "timeout" — but
            // `processSynchronously` is a single blocking C call (sherpa-onnx
            // exposes no progress/abort hook for it) with no `async` suspension
            // point of its own, so `group.cancelAll()` marked the losing child
            // cancelled without actually stopping it. A `TaskGroup` cannot
            // return until every child task finishes, cancelled or not, so
            // that "timeout" never actually returned early — it blocked for
            // the call's full real duration and then discarded a valid,
            // just-slow result in favor of a fabricated timeout error. Running
            // it directly, off the actor, and reporting slowness truthfully
            // (instead of pretending to have aborted anything) has identical
            // real-world latency but keeps the result and tells the truth.
            let started = Date()
            let turns = try await Task.detached(priority: .userInitiated) {
                try Self.processSynchronously(url: url, wrapper: wrapper)
            }.value
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > budget {
                AppLog.transcription.atNotice.notice("SherpaOnnxDiarizer: exceeded its \(String(format: "%.1f", budget), privacy: .public)s budget (took \(String(format: "%.1f", elapsed), privacy: .public)s) — sherpa-onnx exposes no abort hook, so processing ran to completion rather than being interrupted")
            }
            guard !turns.isEmpty else { return [Self.fallbackTurn(for: url)] }
            let smoothed = SpeakerTurnSmoothing.smooth(turns)
            AppLog.transcription.atInfo.info("SherpaOnnxDiarizer: turns \(turns.count, privacy: .public) -> smoothed \(smoothed.count, privacy: .public), speakers=\(Set(smoothed.map { $0.speakerLabel }).count, privacy: .public)")
            return smoothed
        } catch {
            AppLog.transcription.atError.error("SherpaOnnxDiarizer: processing failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return [Self.fallbackTurn(for: url)]
        }
    }

    /// Builds (or rebuilds, if the requested speaker count changed) the
    /// wrapper against the on-disk models. `nil` on any failure — missing
    /// models, unavailable models directory — so callers fall back cleanly.
    private func ensureWrapper(speakerCount: Int) {
        guard speakerCount != currentSpeakerCount || wrapper == nil else { return }
        guard ModelSet.sherpaOnnxDiarization.isInstalled else {
            wrapper = nil
            return
        }
        wrapper = SherpaOnnxOfflineSpeakerDiarizationWrapper(
            segmentationModelPath: SherpaOnnxModelDownloader.segmentationModelURL.path,
            embeddingModelPath: SherpaOnnxModelDownloader.embeddingModelURL.path,
            numSpeakers: Int32(speakerCount),
            numThreads: 2
        )
        currentSpeakerCount = speakerCount
    }

    /// Decodes the file to the wrapper's required sample rate and runs the
    /// synchronous C-backed pipeline. Isolated to a `static` function (rather
    /// than touching actor state) so the blocking call can run off the actor
    /// without holding it for the whole duration.
    private static func processSynchronously(
        url: URL,
        wrapper: SherpaOnnxOfflineSpeakerDiarizationWrapper
    ) throws -> [SpeakerTurn] {
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: Double(wrapper.sampleRate))
        let segments = wrapper.process(samples: samples)
        return turns(from: segments)
    }

    /// Map sherpa-onnx's 0-indexed `speaker` id to "Speaker N" (1-indexed,
    /// first-appearance order) — the same label convention every other
    /// engine in this app uses, so downstream code never has to special-case
    /// a third engine's label format.
    private static func turns(from segments: [SherpaOnnxDiarizationSegmentWrapper]) -> [SpeakerTurn] {
        let ordered = segments.sorted { $0.start < $1.start }
        var labelByID: [Int: String] = [:]
        return ordered.map { segment in
            let label = labelByID[segment.speaker] ?? {
                let next = "Speaker \(labelByID.count + 1)"
                labelByID[segment.speaker] = next
                return next
            }()
            return SpeakerTurn(speakerLabel: label, start: TimeInterval(segment.start), end: TimeInterval(segment.end))
        }
    }
}

#else

/// Built without `SHERPA_ONNX_ENABLED` set (today, always): always falls
/// back to a single speaker turn so `TranscriptionService` keeps working
/// exactly as if this engine were never selected.
actor SherpaOnnxDiarizer: Diarizing {
    /// Nothing to verify without the bridging header/compilation condition
    /// (as in `KurnTests`) — a no-op rather than a throw, since
    /// `SherpaOnnxModelDownloader.download` must still succeed in this
    /// configuration (it only fetches bytes over HTTP).
    static func verifyModelsLoad() async throws {}

    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, speakerCount: 0)
    }

    func diarize(url: URL, speakerCount: Int) async -> [SpeakerTurn] {
        let message = NSLocalizedString("settings.sherpa_onnx.package_missing", comment: "sherpa-onnx package missing")
        AppLog.transcription.atError.error("SherpaOnnxDiarizer: \(message, privacy: .public)")
        return [Self.fallbackTurn(for: url)]
    }
}

#endif

// MARK: - Shared helpers
//
// Outside the compilation-condition split: both build configurations need
// the same fallback turn and the same processing budget.

extension SherpaOnnxDiarizer {
    /// A single speaker turn spanning the whole clip, used whenever
    /// diarization can't produce real turns.
    fileprivate static func fallbackTurn(for url: URL) -> SpeakerTurn {
        SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, audioDuration(of: url)))
    }

    fileprivate static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Processing budget scaled to the recording — reported, not enforced
    /// (H8 PR 18): sherpa-onnx exposes no way to abort an in-flight call, so
    /// exceeding this only logs, it never cancels. Deliberately more
    /// generous than `FluidAudioDiarizer.processTimeout`'s `duration * 0.5`:
    /// that budget assumes ANE-accelerated inference ("runs well under real
    /// time on the ANE"), which this CPU-only ONNX Runtime engine has no
    /// equivalent guarantee for. This multiplier is a placeholder pending
    /// real device measurement (see the public-dataset evaluation harness,
    /// `docs/roadmap.md` D4) — tune it once that data exists rather than
    /// guessing further.
    static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(3600, max(300, duration * 1.5))
    }
}
