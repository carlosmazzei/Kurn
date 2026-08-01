//
//  AudioFixtures.swift
//  KurnTests
//
//  Shared synthetic-audio generators. Replaces the per-file `makeToneFile`
//  copies that used to live in AudioPreprocessorTests / RecordingRecoveryTests.
//
//  Three flavours:
//   - `m4aTone` writes a lossy AAC .m4a, matching how the app records audio
//     (used by the preprocessor / recovery / chunker tests).
//   - `wav` writes lossless Linear PCM so silence is *exactly* silent and tones
//     are clean — important for the DSP/diarization tests, where AAC encoder
//     noise could otherwise blur silence gaps or timbre features.
//   - `prerecordedM4A` copies an AAC file that ships with the test bundle, for
//     the tests whose subject *is* reading and re-encoding an .m4a. Encoding
//     the input on the simulator makes those tests depend on the AAC writer
//     they are not testing, and an unfinalized container there is
//     indistinguishable from the failure they look for.
//

import AVFoundation
import Foundation
@testable import Kurn

enum AudioFixtures {

    /// The AAC files checked into `KurnTests/Support/Fixtures`, copied into the
    /// test bundle by the synchronized `KurnTests` group.
    enum Prerecorded: String {
        /// 6 s mono sine at 44.1 kHz / 128 kbps — the shape the recorder
        /// produced before the fixed 24 kHz storage format, i.e. worth
        /// compacting.
        case tone44kHz128kbps6s = "tone-44100-128kbps-6s"
        /// 2 s mono sine at 16 kHz, as a narrowband Bluetooth route would have
        /// produced: already below the storage rate.
        case tone16kHz2s = "tone-16000-2s"
    }

    /// Copy a prerecorded fixture to `url`, replacing whatever is there.
    @discardableResult
    static func prerecordedM4A(_ fixture: Prerecorded, at url: URL) throws -> URL {
        guard let source = Bundle(for: BundleToken.self)
            .url(forResource: fixture.rawValue, withExtension: "m4a") else {
            throw AppError.audioError("Fixture \(fixture.rawValue).m4a is missing from the test bundle")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

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
        return url
    }
}

/// Locates the test bundle: `Bundle(for:)` needs a class, and the suites are
/// Swift Testing structs.
private final class BundleToken {}
