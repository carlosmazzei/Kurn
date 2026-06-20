//
//  TranscriptionTypes.swift
//  MeetSync
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
