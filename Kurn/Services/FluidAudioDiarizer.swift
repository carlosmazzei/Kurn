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
    private let manager = OfflineDiarizerManager()
    private var modelsReady = false
    private let prepareTimeout: TimeInterval = 60
    private let processTimeout: TimeInterval = 120

    func diarize(url: URL) async -> [SpeakerTurn] {
        await diarize(url: url, onDownloadFailure: nil)
    }

    /// - Parameter onDownloadFailure: reported only for a model preparation
    ///   failure (the one case where re-consenting/redownloading could help).
    ///   Passed per call, not stored on the actor, so concurrent transcriptions
    ///   of different recordings can't have their warning handlers cross over.
    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        if !modelsReady {
            do {
                try await Self.withTimeout(seconds: prepareTimeout) {
                    try await self.manager.prepareModels()
                }
                modelsReady = true
            } catch {
                AppLog.transcription.error("FluidAudioDiarizer: model preparation failed: \(error.localizedDescription, privacy: .public)")
                onDownloadFailure?(error.localizedDescription)
                return [Self.fallbackTurn(for: url)]
            }
        }
        do {
            let result = try await Self.withTimeout(seconds: processTimeout) {
                try await self.manager.process(url)
            }
            return Self.turns(from: result.segments)
        } catch {
            // Not a download/consent problem (models are already prepared) —
            // log it, but don't route it through the download-failure banner,
            // which would mislead the user into re-consenting for no reason.
            AppLog.transcription.error("FluidAudioDiarizer: processing failed: \(error.localizedDescription, privacy: .public)")
            return [Self.fallbackTurn(for: url)]
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
        await diarize(url: url, onDownloadFailure: nil)
    }

    func diarize(url: URL, onDownloadFailure: (@Sendable (String) -> Void)?) async -> [SpeakerTurn] {
        let message = NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        AppLog.transcription.error("FluidAudioDiarizer: \(message, privacy: .public)")
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
