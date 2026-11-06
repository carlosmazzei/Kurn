//
//  FluidAudioVAD.swift
//  Kurn
//
//  Voice-activity detection backed by FluidAudio's Silero VAD CoreML model.
//  Mirrors `FluidAudioDiarizer`'s contract: never throws out of `detectSpeech` —
//  on any failure (missing model, decode error, timeout) it falls back to a
//  single region covering the whole clip, so the pipeline keeps working.
//
//  FluidAudio's `segmentSpeech` already returns padded speech intervals with
//  absolute start/end times, so this engine only has to load 16 kHz mono samples
//  and map `VadSegment` → `SpeechRegion`.
//

import AVFoundation
import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioVAD: VoiceActivityDetecting {

    /// Lazily loaded and reused across recordings — model load is expensive.
    private var manager: VadManager?
    /// Reported, not enforced: cancellation is checked between chunks, but
    /// FluidAudio exposes no abort hook for an in-flight CoreML call.
    private let budget: TimeInterval = 120

    func detectSpeech(url: URL) async -> [SpeechRegion] {
        guard !Task.isCancelled else {
            AppLog.transcription.atNotice.notice("FluidAudioVAD: cancelled before starting")
            return [AudioFileDuration.wholeClipRegion(for: url)]
        }
        do {
            let started = Date()
            let regions = try await segment(url: url)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > self.budget {
                AppLog.transcription.atNotice.notice("FluidAudioVAD: exceeded its \(Int(self.budget))s budget (took \(String(format: "%.1f", elapsed), privacy: .public)s) — FluidAudio's VadManager exposes no abort hook, so processing ran to completion rather than being interrupted")
            }
            return regions
        } catch is CancellationError {
            // The non-throwing protocol still requires a value. The pipeline's
            // cancellation barrier immediately after VAD will discard it.
            AppLog.transcription.atNotice.notice("FluidAudioVAD: cancelled")
            return [AudioFileDuration.wholeClipRegion(for: url)]
        } catch {
            AppLog.transcription.atError.error("FluidAudioVAD: failed, using whole-clip fallback code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return [AudioFileDuration.wholeClipRegion(for: url)]
        }
    }

    /// Isolated so the non-`Sendable` `VadManager` never crosses out of the actor.
    private func segment(url: URL) async throws -> [SpeechRegion] {
        let manager = try await loadedManager()
        var state = await manager.makeStreamState()
        let analysis = try await VADProbabilityReader.read(url: url, sampleRate: Double(VadManager.sampleRate)) { samples in
            let result = try await manager.processStreamingChunk(samples, state: state)
            state = result.state
            return result.probability
        }
        let unusedState = VadState.initial()
        // Offline segmentation consumes only probabilities, not streaming events.
        let results = analysis.probabilities.map {
            VadResult(probability: $0, isVoiceActive: false, processingTime: 0, outputState: unusedState)
        }
        let segments = await manager.segmentSpeech(from: results, totalSamples: analysis.sampleCount)
        AppLog.transcription.atInfo.info("FluidAudioVAD: segments=\(segments.count, privacy: .public)")
        // No detected speech → the whole clip as one region rather than
        // nothing, so downstream consumers stay well-defined.
        return SpeechRegionNormalization.regions(
            segments.map { SpeechRegion(start: $0.startTime, end: $0.endTime) },
            clipDuration: AudioFileDuration.seconds(of: url)
        )
    }

    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let created = try await VadManager()
        manager = created
        AppLog.transcription.atNotice.notice("FluidAudioVAD: Silero VAD model loaded")
        return created
    }
}

#else

/// Built without the FluidAudio package linked: falls back to a single whole-clip
/// region (no trimming, single speaker) so the pipeline keeps working.
actor FluidAudioVAD: VoiceActivityDetecting {
    func detectSpeech(url: URL) async -> [SpeechRegion] {
        [AudioFileDuration.wholeClipRegion(for: url)]
    }
}

#endif
