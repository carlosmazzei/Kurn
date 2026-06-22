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

import FluidAudio
import Foundation

actor FluidAudioDiarizer: Diarizing {
    private var onDownloadFailure: (@Sendable (String) -> Void)?
    private let manager = OfflineDiarizerManager()
    private var modelsReady = false

    /// Set before `diarize(url:)` to learn about non-fatal failures (e.g. a
    /// model download error) without interrupting transcription.
    func setOnDownloadFailure(_ handler: (@Sendable (String) -> Void)?) {
        onDownloadFailure = handler
    }

    func diarize(url: URL) async -> [SpeakerTurn] {
        do {
            if !modelsReady {
                try await manager.prepareModels()
                modelsReady = true
            }
            let result = try await manager.process(url)
            return Self.turns(from: result.segments)
        } catch {
            onDownloadFailure?(error.localizedDescription)
            return [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0)]
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
}
