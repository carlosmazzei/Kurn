//
//  DiarizationPreprocessorTests.swift
//  KurnTests
//
//  Verifies the diarization-tuned preprocessor produces uncompressed mono
//  16 kHz Float32 WAV, peak-normalizes to the expected target without
//  clipping, and reduces a stationary noise floor enough to help embedding
//  models (without crushing the speech signal).
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct DiarizationPreprocessorTests {

    @Test func processProducesMono16kHzFloat32WAV() async throws {
        let inputURL = try AudioFixtures.m4aTone(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let preprocessor = DiarizationPreprocessor()
        let outURL = try await preprocessor.process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outFile = try AVAudioFile(forReading: outURL)
        #expect(outFile.fileFormat.sampleRate == 16_000)
        #expect(outFile.fileFormat.channelCount == 1)
        #expect(outFile.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(outFile.length > 0)
    }

    @Test func processProducesUncompressedPCM() async throws {
        let inputURL = try AudioFixtures.m4aTone(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outURL = try await DiarizationPreprocessor().process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outFile = try AVAudioFile(forReading: outURL)
        let formatID = outFile.fileFormat.streamDescription.pointee.mFormatID
        #expect(formatID == kAudioFormatLinearPCM)
    }

    @Test func processPeakNormalizesToTargetWithin1dB() async throws {
        // Pre-normalized loud-ish source so the global gain doesn't have to
        // clamp; the preprocessor's target is -3 dBFS within ±1 dB.
        let inputURL = try AudioFixtures.m4aTone(seconds: 1.5, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outURL = try await DiarizationPreprocessor().process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let samples = try Self.readWAVSamples(url: outURL)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0)
        let peakDB = 20 * log10(peak)
        #expect(abs(peakDB - (-3.0)) < 1.0)
    }

    @Test func processDoesNotClip() async throws {
        let inputURL = try AudioFixtures.m4aTone(seconds: 1.5, amplitude: 0.9)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outURL = try await DiarizationPreprocessor().process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let samples = try Self.readWAVSamples(url: outURL)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak < 1.0)
    }

    @Test func processReducesStationaryNoiseFloor() async throws {
        // Build a fixture with two clear regions on a continuous noise bed:
        //   [0.0s..1.5s] silence + white noise (used for noise-floor estimation)
        //   [1.5s..3.0s] sine tone + same white noise
        // After preprocessing, the noise-only region's RMS should drop
        // substantially (spectral subtraction) while the tone region still
        // contains energy at the tone band.
        let inputURL = try Self.makeNoisyToneWAV(
            durationSilent: 1.5,
            durationTone: 1.5,
            toneHz: 440,
            toneAmplitude: 0.3,
            noiseAmplitude: 0.05
        )
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outURL = try await DiarizationPreprocessor().process(url: inputURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outSamples = try Self.readWAVSamples(url: outURL)
        let sampleRate = 16_000
        // Inset a bit from each boundary to avoid edge artifacts from the
        // STFT overlap-add. Take the middle ~1.0 s of each region.
        let silenceStart = Int(0.25 * Double(sampleRate))
        let silenceEnd = Int(1.25 * Double(sampleRate))
        let toneStart = Int(1.75 * Double(sampleRate))
        let toneEnd = Int(2.75 * Double(sampleRate))
        guard outSamples.count >= toneEnd else {
            Issue.record("Output WAV shorter than expected: \(outSamples.count) samples")
            return
        }
        let silenceRMS = Self.rms(of: outSamples[silenceStart..<silenceEnd])
        let toneRMS = Self.rms(of: outSamples[toneStart..<toneEnd])

        // Tone should still be loud relative to the cleaned noise floor: the
        // tone-vs-silence ratio should be much larger after denoise than the
        // input's ratio (~0.3 / 0.05 = 6:1 for the synthesized signal). A 20×
        // post-cleanup ratio confirms the noise floor was meaningfully reduced
        // without destroying the tone.
        #expect(toneRMS > silenceRMS * 20)
    }

    @Test func cleanupOnlyRemovesFilesInsideTemporaryDirectory() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0x01]).write(to: tmpURL)

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0x02]).write(to: documentsURL)
        defer { try? FileManager.default.removeItem(at: documentsURL) }

        let preprocessor = DiarizationPreprocessor()
        await preprocessor.cleanup(tmpURL)
        await preprocessor.cleanup(documentsURL)

        #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
        #expect(FileManager.default.fileExists(atPath: documentsURL.path))
    }

    // MARK: - Helpers

    /// Decode a Float32 mono WAV produced by the preprocessor into a `[Float]`.
    private static func readWAVSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AppError.audioError("Could not allocate read buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// RMS amplitude of an arbitrary float slice.
    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(into: Float(0)) { $0 += $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }

    /// Write a lossless 16 kHz mono WAV with [silence+noise][tone+noise]. The
    /// fixture has a clear "quietest" region the preprocessor can use to
    /// estimate its stationary noise floor.
    private static func makeNoisyToneWAV(
        durationSilent: Double,
        durationTone: Double,
        toneHz: Double,
        toneAmplitude: Float,
        noiseAmplitude: Float
    ) throws -> URL {
        let url = AudioFixtures.tempURL(ext: "wav")
        let sampleRate: Double = 16_000
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat

        // Deterministic white-noise generator so tests are reproducible.
        var state: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        func nextNoise() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let bits = UInt32(truncatingIfNeeded: state >> 32)
            let normalized = Float(bits) / Float(UInt32.max) // 0...1
            return (normalized * 2 - 1) * noiseAmplitude
        }

        try writeRegion(file: file, format: format, sampleRate: sampleRate,
                        seconds: durationSilent, toneHz: 0,
                        toneAmplitude: 0, noise: nextNoise)
        try writeRegion(file: file, format: format, sampleRate: sampleRate,
                        seconds: durationTone, toneHz: toneHz,
                        toneAmplitude: toneAmplitude, noise: nextNoise)
        return url
    }

    private static func writeRegion(
        file: AVAudioFile,
        format: AVAudioFormat,
        sampleRate: Double,
        seconds: Double,
        toneHz: Double,
        toneAmplitude: Float,
        noise: () -> Float
    ) throws {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else {
            throw AppError.audioError("Could not allocate fixture buffer")
        }
        buffer.frameLength = frames
        let omega = 2.0 * Double.pi * toneHz
        for i in 0..<Int(frames) {
            let tone = toneHz > 0 ? Float(sin(omega * Double(i) / sampleRate)) * toneAmplitude : 0
            data[0][i] = tone + noise()
        }
        try file.write(from: buffer)
    }
}
