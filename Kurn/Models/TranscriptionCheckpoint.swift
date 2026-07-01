//
//  TranscriptionCheckpoint.swift
//  Kurn
//
//  Durable progress of a chunked transcription, persisted on `Recording` (as
//  JSON Data) after every completed chunk. When a long transcription is
//  interrupted — the app is backgrounded past its grace window, killed, or the
//  user cancels — the next attempt re-derives the same chunk plan and continues
//  from `completedChunks` instead of re-transcribing (or re-uploading) hours of
//  audio. Timestamps are on the timeline of the audio actually fed to the
//  engine (the VAD-compacted copy when compaction ran); the pipeline re-runs
//  the deterministic preprocessing/VAD stages on resume, and a plan mismatch
//  (different chunk count, engine, or language) discards the checkpoint.
//

import Foundation

struct TranscriptionCheckpoint: Codable, Sendable {
    /// `TranscriptionEngine.rawValue` the chunks were transcribed with.
    var engineRaw: String
    /// `MeetingLanguage.rawValue` the transcription was requested in.
    var languageRaw: String
    /// Whether the engine input was the VAD-compacted copy. Spans live on that
    /// input's timeline, so a resume that compacts differently can't reuse them.
    var compacted: Bool
    /// Chunk count of the plan these spans belong to. A resume whose re-derived
    /// plan has a different count must start over.
    var totalChunks: Int
    /// Chunks fully transcribed so far; the resume starts at this index.
    var completedChunks: Int
    /// Language reported by the engine for the first chunk (may be empty).
    var detectedLanguage: String
    /// Spans of every completed chunk, already offset to the input's timeline.
    var spans: [Span]

    struct Span: Codable, Sendable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var confidence: Float?
    }

    /// Whether this checkpoint can seed a resume of the given run.
    func matches(engine: TranscriptionEngine, language: MeetingLanguage, compacted: Bool) -> Bool {
        engineRaw == engine.rawValue && languageRaw == language.rawValue && self.compacted == compacted
    }
}
