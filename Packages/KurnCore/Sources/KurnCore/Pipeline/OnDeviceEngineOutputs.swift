//
//  OnDeviceEngineOutputs.swift
//  KurnCore
//
//  The engine-independent half of the on-device FluidAudio engines: what a
//  VAD's raw intervals and a batch ASR's raw text and word timings become in
//  the app's own types. `FluidAudioVAD` and `FluidAudioTranscriber` only read
//  FluidAudio's types into these values.
//

import Foundation

public enum SpeechRegionNormalization {
    /// One region spanning the whole clip — what every VAD falls back to when
    /// it cannot say anything better, so downstream consumers stay well-defined.
    public static func wholeClip(duration: TimeInterval) -> SpeechRegion {
        SpeechRegion(start: 0, end: max(0, duration))
    }

    /// Drops empty or inverted intervals; with nothing left, returns the
    /// whole-clip region rather than no speech at all.
    public static func regions(_ raw: [SpeechRegion], clipDuration: TimeInterval) -> [SpeechRegion] {
        let regions = raw.filter { $0.end > $0.start }
        return regions.isEmpty ? [wholeClip(duration: clipDuration)] : regions
    }
}

public enum BatchTranscriptAssembly {
    /// FluidAudio only runs a progress session for clips longer than its
    /// internal chunking threshold (`maxModelSamples`, 15 s at 16 kHz). Opening
    /// the stream for a shorter clip would leave a session nothing finishes.
    public static let progressThreshold: TimeInterval = 15.5

    public static func reportsProgress(forDuration duration: TimeInterval) -> Bool {
        duration > progressThreshold
    }

    public static func clampedFraction(_ fraction: Double) -> Double {
        min(1, max(0, fraction))
    }

    /// The transcript for one batch pass: no spans when the text is blank,
    /// otherwise one span per word when timings exist and one whole-clip span
    /// when they do not. The language is left to the pipeline.
    public static func transcript(text: String, words: [TimedWord], duration: TimeInterval) -> RawTranscript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RawTranscript(spans: [], language: "") }
        let spans = TimedWordSpanBuilder.spans(from: words, fallbackText: trimmed, duration: duration)
        return RawTranscript(spans: spans, language: "")
    }
}
