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
    /// Processing budget — reported, not enforced (H8 PR 18). FluidAudio's
    /// `VadManager` checks no cancellation anywhere in its per-chunk loop and
    /// its CoreML call is synchronous, so there is no engine hook to abort
    /// an in-flight call. This used to be raced against `segment(url:)` in a
    /// `TaskGroup` and called a "timeout" — but a `TaskGroup` cannot return
    /// until every child task finishes, cancelled or not, so that race never
    /// actually bounded wall-clock time: it blocked for `segment`'s full
    /// real duration and then discarded a valid, just-slow result for a
    /// fabricated timeout error. Calling `segment` directly has identical
    /// real-world latency but keeps the result and reports slowness
    /// truthfully instead of pretending to have aborted anything.
    private let budget: TimeInterval = 120

    func detectSpeech(url: URL) async -> [SpeechRegion] {
        guard !Task.isCancelled else {
            AppLog.transcription.atNotice.notice("FluidAudioVAD: cancelled before starting")
            return [Self.fallbackRegion(for: url)]
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
            return [Self.fallbackRegion(for: url)]
        } catch {
            AppLog.transcription.atError.error("FluidAudioVAD: failed, using whole-clip fallback code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return [Self.fallbackRegion(for: url)]
        }
    }

    /// Isolated so the non-`Sendable` `VadManager` never crosses out of the actor.
    private func segment(url: URL) async throws -> [SpeechRegion] {
        let manager = try await loadedManager()
        let samples = try VADAudioLoader.monoSamples(url: url, sampleRate: Double(VadManager.sampleRate))
        guard !samples.isEmpty else { return [Self.fallbackRegion(for: url)] }

        let segments = try await manager.segmentSpeech(samples)
        let regions = segments
            .map { SpeechRegion(start: $0.startTime, end: $0.endTime) }
            .filter { $0.end > $0.start }
        AppLog.transcription.atInfo.info("FluidAudioVAD: regions=\(regions.count, privacy: .public)")
        // No detected speech → treat the whole clip as one region rather than
        // returning nothing, so downstream consumers stay well-defined.
        return regions.isEmpty ? [Self.fallbackRegion(for: url)] : regions
    }

    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let created = try await VadManager()
        manager = created
        AppLog.transcription.atNotice.notice("FluidAudioVAD: Silero VAD model loaded")
        return created
    }

    private static func fallbackRegion(for url: URL) -> SpeechRegion {
        let duration: TimeInterval
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else {
            duration = 0
        }
        return SpeechRegion(start: 0, end: max(0, duration))
    }
}

#else

/// Built without the FluidAudio package linked: falls back to a single whole-clip
/// region (no trimming, single speaker) so the pipeline keeps working.
actor FluidAudioVAD: VoiceActivityDetecting {
    func detectSpeech(url: URL) async -> [SpeechRegion] {
        let duration: TimeInterval
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else {
            duration = 0
        }
        return [SpeechRegion(start: 0, end: max(0, duration))]
    }
}

#endif
