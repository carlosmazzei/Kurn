//
//  AudioFileDuration.swift
//  Kurn
//
//  The duration the on-device engines fall back on when they cannot produce
//  real output: one whole-clip speech region or speaker turn. Used to be a
//  private copy in each of `FluidAudioVAD`, `FluidAudioDiarizer` and
//  `SherpaOnnxDiarizer`; one definition keeps their fallbacks identical and
//  testable without the models those engines need.
//

import AVFoundation
import Foundation
import KurnCore

enum AudioFileDuration {
    /// Seconds of audio in the file, or `0` when it cannot be opened or
    /// reports no sample rate — a fallback must never fail itself.
    static func seconds(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// A single speaker turn spanning the whole clip, used whenever
    /// diarization can't produce real turns — covering the full duration
    /// (instead of a zero-length range) keeps speaker-label lookups meaningful.
    static func wholeClipTurn(for url: URL) -> SpeakerTurn {
        SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: max(0, seconds(of: url)))
    }

    /// A single speech region spanning the whole clip, the VAD fallback.
    static func wholeClipRegion(for url: URL) -> SpeechRegion {
        SpeechRegionNormalization.wholeClip(duration: seconds(of: url))
    }
}
