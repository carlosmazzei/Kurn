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
import Foundation
@testable import Kurn

enum AudioFixtures {

    /// A unique throwaway URL in the temporary directory.
    static func tempURL(ext: String = "m4a") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Write a mono AAC .m4a sine tone (or silence when `hz == 0`).
    @discardableResult
    static func m4aTone(
        hz: Double = 440,
        seconds: Double = 1.0,
        sampleRate: Double = 44_100,
        amplitude: Float = 0.5,
        at url: URL? = nil
    ) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        return try encode(
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
        sampleRate: Double = 44_100,
        amplitude: Float = 0.5,
        at url: URL? = nil
    ) throws -> URL {
        // Build a canonical 16-bit PCM WAV by hand and write the bytes directly,
        // instead of using AVAudioFile's writer. On the CI simulator runtime that
        // writer produced a valid header but an empty data chunk: the file opened
        // yet read back 0 frames, collapsing the diarizer to its single-speaker
        // fallback. Reading a hand-written WAV via AVAudioFile works fine, so only
        // the write path needs replacing.
        let target = url ?? tempURL(ext: "wav")
        let data = wavData(segments: segments, sampleRate: sampleRate, amplitude: amplitude)
        try data.write(to: target)
        return target
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

    // MARK: - Manual WAV encoding

    /// Canonical mono 16-bit little-endian PCM WAV bytes for the given segments.
    private static func wavData(
        segments: [(hz: Double, seconds: Double)],
        sampleRate: Double,
        amplitude: Float
    ) -> Data {
        var samples: [Int16] = []
        for segment in segments {
            let frameCount = max(0, Int(sampleRate * segment.seconds))
            if segment.hz > 0 {
                let omega = 2.0 * Double.pi * segment.hz
                for i in 0..<frameCount {
                    let value = Float(sin(omega * Double(i) / sampleRate)) * amplitude
                    samples.append(pcm16(value))
                }
            } else {
                samples.append(contentsOf: repeatElement(0, count: frameCount))
            }
        }

        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * bytesPerSample
        let blockAlign = channels * UInt16(bytesPerSample)
        let dataSize = UInt32(samples.count) * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36) + dataSize)         // RIFF chunk size
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))                     // PCM fmt chunk size
        data.appendLE(UInt16(1))                      // audioFormat = PCM
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(dataSize)
        // Store samples little-endian explicitly so the bytes are correct
        // regardless of host endianness.
        let leSamples = samples.map { $0.littleEndian }
        leSamples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }
        return data
    }

    private static func pcm16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        return Int16((clamped * 32_767.0).rounded())
    }

    // MARK: - AVAudioFile encoding (AAC / .m4a)

    private static func encode(
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

private extension Data {
    /// Append a fixed-width integer in little-endian byte order.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
