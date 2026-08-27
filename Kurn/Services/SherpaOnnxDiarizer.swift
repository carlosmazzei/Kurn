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

#if SHERPA_ONNX_ENABLED

actor SherpaOnnxDiarizer: Diarizing {
    private var wrapper: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    private var currentSpeakerCount = 0
    private var modelsReady = false

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
        let timeout = Self.processTimeout(forAudioDuration: duration)
        AppLog.transcription.atNotice.notice("SherpaOnnxDiarizer: processing file=\(url.lastPathComponent, privacy: .public) audio=\(String(format: "%.1f", duration), privacy: .public)s timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
        do {
            let turns = try await Self.withTimeout(seconds: timeout) {
                try Self.processSynchronously(url: url, wrapper: wrapper)
            }
            guard !turns.isEmpty else { return [Self.fallbackTurn(for: url)] }
            let smoothed = SpeakerTurnSmoothing.smooth(turns)
            AppLog.transcription.atInfo.info("SherpaOnnxDiarizer: turns \(turns.count, privacy: .public) -> smoothed \(smoothed.count, privacy: .public), speakers=\(Set(smoothed.map { $0.speakerLabel }).count, privacy: .public)")
            return smoothed
        } catch {
            AppLog.transcription.atError.error("SherpaOnnxDiarizer: processing failed: \(error.localizedDescription, privacy: .public)")
            return [Self.fallbackTurn(for: url)]
        }
    }

    /// Builds (or rebuilds, if the requested speaker count changed) the
    /// wrapper against the on-disk models. `nil` on any failure — missing
    /// models, unavailable models directory — so callers fall back cleanly.
    private func ensureWrapper(speakerCount: Int) {
        guard speakerCount != currentSpeakerCount || wrapper == nil else { return }
        guard SherpaOnnxModelDownloader.isInstalled else {
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

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try operation() }
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

/// Built without `SHERPA_ONNX_ENABLED` set (today, always): always falls
/// back to a single speaker turn so `TranscriptionService` keeps working
/// exactly as if this engine were never selected.
actor SherpaOnnxDiarizer: Diarizing {
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

    /// Processing budget scaled to the recording. Deliberately more generous
    /// than `FluidAudioDiarizer.processTimeout`'s `duration * 0.5`: that
    /// budget assumes ANE-accelerated inference ("runs well under real time
    /// on the ANE"), which this CPU-only ONNX Runtime engine has no
    /// equivalent guarantee for. This multiplier is a placeholder pending
    /// real device measurement (see the public-dataset evaluation harness,
    /// `docs/roadmap.md` D4) — tune it once that data exists rather than
    /// guessing further.
    static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(3600, max(300, duration * 1.5))
    }
}
