//
//  TranscriptionTypes.swift
//  Kurn
//
//  Provider-agnostic intermediate types produced by the transcription engines
//  (on-device or Whisper) before speaker diarization is layered on top.
//

import Foundation

/// A timed span of recognized text, before speaker attribution.
struct TranscribedSpan: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
}

/// The raw output of a transcription engine: ordered spans + detected language.
struct RawTranscript: Sendable {
    var spans: [TranscribedSpan]
    /// BCP-47 (or two-letter) locale string, may be empty if unknown.
    var language: String
}

/// A diarized speaker turn: which speaker spoke during [start, end).
struct SpeakerTurn: Sendable, Hashable {
    var speakerLabel: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A speaker diarization engine. Implementations must never throw — on any
/// failure they should fall back to a single turn covering the whole clip, so
/// `TranscriptionService` always gets usable output.
protocol Diarizing: Sendable {
    func diarize(url: URL) async -> [SpeakerTurn]
}
