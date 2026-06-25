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

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioVAD: VoiceActivityDetecting {

    /// Lazily loaded and reused across recordings — model load is expensive.
    private var manager: VadManager?
    private let timeout: TimeInterval = 120

    func detectSpeech(url: URL) async -> [SpeechRegion] {
        do {
            return try await Self.withTimeout(seconds: timeout) {
                try await self.segment(url: url)
            }
        } catch {
            AppLog.transcription.atError.error("FluidAudioVAD: failed, using whole-clip fallback: \(error.localizedDescription, privacy: .public)")
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
