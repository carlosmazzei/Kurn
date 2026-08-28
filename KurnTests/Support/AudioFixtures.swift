//
//  AudioFixtures.swift
//  KurnTests
//
//  Shared synthetic-audio generators. Replaces the per-file `makeToneFile`
//  copies that used to live in AudioPreprocessorTests / RecordingRecoveryTests.
//
//  Two flavours:
//   - `m4aTone` writes a lossy AAC .m4a, matching how the app records audio
//     (used by the preprocessor / recovery / chunker tests).
//   - `wav` writes lossless Linear PCM so silence is *exactly* silent and tones
//     are clean — important for the DSP/diarization tests, where AAC encoder
//     noise could otherwise blur silence gaps or timbre features.
//

import AVFoundation
import KurnCore
import Foundation
@testable import Kurn

enum AudioFixtures {

    /// A unique throwaway URL in the temporary directory.
    static func tempURL(ext: String = "m4a") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Write a mono AAC .m4a sine tone (or silence when `hz == 0`).
    ///
    /// Pass `bitRate: nil` to let the codec pick. AAC's valid bit rates depend on
    /// the sample rate — the 64 kbps default is fine at 44.1 kHz but is rejected
    /// outright at 16 kHz, which throws out of `AVAudioFile`'s initializer.
    @discardableResult
    static func m4aTone(
        hz: Double = 440,
        seconds: Double = 1.0,
        sampleRate: Double = 44_100,
        amplitude: Float = 0.5,
        bitRate: Int? = 64_000,
        at url: URL? = nil
    ) throws -> URL {
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        if let bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        }
        return try write(
            segments: [(hz, seconds)],
            sampleRate: sampleRate,
            amplitude: amplitude,
            settings: settings,
            to: url ?? tempURL(ext: "m4a")
        )
    }

    /// Write lossless mono PCM .wav from a list of `(hz, seconds)` segments. A
    /// segment with `hz == 0` is exact silence.
    @discardableResult
    static func wav(
        segments: [(hz: Double, seconds: Double)],
        sampleRate: Double = 16_000,
        amplitude: Float = 0.5,
        at url: URL? = nil
    ) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try write(
            segments: segments,
            sampleRate: sampleRate,
            amplitude: amplitude,
            settings: settings,
            to: url ?? tempURL(ext: "wav")
        )
    }

    /// Tone → silence → tone at a clearly different pitch. The two well-separated
    /// F0 values (and their differing zero-crossing rates) make the heuristic
    /// diarizer cluster them as two distinct speakers.
    static func twoSpeakerWAV() throws -> URL {
        try wav(segments: [(110, 1.5), (0, 0.9), (240, 1.5)])
    }

    /// Tone → silence → tone at the *same* pitch: expected to stay one speaker.
    static func sameSpeakerWAV() throws -> URL {
        try wav(segments: [(140, 1.5), (0, 0.9), (140, 1.5)])
    }

    private static func write(
        segments: [(hz: Double, seconds: Double)],
        sampleRate: Double,
        amplitude: Float,
        settings: [String: Any],
        to url: URL
    ) throws -> URL {
        // `AVAudioFile` has no `close()`. An MP4 container's `moov` atom is
        // written when the *writer deallocates*, so a fixture handed to a test
        // before that happens is a truncated file with no duration — which is
        // what `RecordingCompactorTests` kept hitting on CI ("is not readable;
        // leaving it alone", then `AVErrorFailedDependenciesKey=(Duration)`).
        // The pool gives the release a known point instead of leaving it to ARC
        // and the optimizer.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            for segment in segments {
                let frameCount = AVAudioFrameCount(sampleRate * segment.seconds)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                      let data = buffer.floatChannelData else {
                    throw AppError.audioError("Could not build tone buffer")
                }
                buffer.frameLength = frameCount
                if segment.hz > 0 {
                    let omega = 2.0 * Double.pi * segment.hz
                    for i in 0..<Int(frameCount) {
                        data[0][i] = Float(sin(omega * Double(i) / sampleRate)) * amplitude
                    }
                } else {
                    for i in 0..<Int(frameCount) { data[0][i] = 0 }
                }
                try file.write(from: buffer)
            }
        }

        // And prove it. Opening is exactly the operation that fails on an
        // unfinalized container, so a fixture that isn't ready fails here, by
        // name, instead of surfacing three layers away as a test about
        // something else entirely.
        try autoreleasepool {
            do {
                _ = try AVAudioFile(forReading: url)
            } catch {
                throw AppError.audioError(
                    "Fixture \(url.lastPathComponent) is not readable after writing: \(error.localizedDescription)"
                )
            }
        }
        return url
    }
}
