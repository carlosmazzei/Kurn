//
//  STFTTests.swift
//  KurnTests
//
//  Guards the `forward`/`inverse` pair that `Dereverberation` is built on. The
//  spectral-subtraction path (`magnitudes`, `processFrame`) is covered
//  indirectly by DiarizationPreprocessorTests.
//

import Foundation
import Testing
@testable import Kurn

struct STFTTests {

    /// Analysis-only Hann windowing at hop = N/2 overlap-adds back to ~1.0, so a
    /// forward transform followed by an inverse must return the original signal.
    /// This is the property the whole file relies on — without it, any spectral
    /// edit would come back with an amplitude ripple riding on it.
    @Test func forwardInverseRoundTripReconstructsTheSignal() {
        let stft = STFT(frameSize: 512, hopSize: 256)
        let samples = Self.noise(count: 8192)

        let frames = stft.frameCount(forSampleCount: samples.count)
        #expect(frames > 0)

        var real = [Float](repeating: 0, count: frames * stft.binCount)
        var imag = [Float](repeating: 0, count: frames * stft.binCount)
        for t in 0..<frames {
            stft.forward(
                samples: samples,
                frameStart: t * stft.hopSize,
                real: &real, imag: &imag,
                offset: t * stft.binCount
            )
        }

        var reconstructed = [Float](repeating: 0, count: samples.count)
        for t in 0..<frames {
            let frame = stft.inverse(real: real, imag: imag, offset: t * stft.binCount)
            let start = t * stft.hopSize
            for i in 0..<stft.frameSize {
                reconstructed[start + i] += frame[i]
            }
        }

        // The leading and trailing half-frames see only one window instead of
        // two, so the sum-to-one property does not hold there.
        var maxError: Float = 0
        for i in stft.frameSize..<(samples.count - stft.frameSize) {
            maxError = max(maxError, abs(reconstructed[i] - samples[i]))
        }
        #expect(maxError < 1e-4)
    }

    @Test func frameCountMatchesTheHopLayout() {
        let stft = STFT(frameSize: 512, hopSize: 256)
        #expect(stft.frameCount(forSampleCount: 511) == 0)
        #expect(stft.frameCount(forSampleCount: 512) == 1)
        #expect(stft.frameCount(forSampleCount: 768) == 2)
        #expect(stft.binCount == 257)
    }

    /// vDSP accepts `f·2ⁿ` sizes, not only powers of two. DPDFNet was trained on
    /// a 320-sample frame (`5·2⁶`), so padding it to 512 would change its input.
    @Test func nonPowerOfTwoFrameRoundTrips() {
        let stft = STFT(frameSize: 320, hopSize: 160)
        let samples = Self.noise(count: 8_000)
        let frames = stft.frameCount(forSampleCount: samples.count)
        var real = [Float](repeating: 0, count: frames * stft.binCount)
        var imaginary = [Float](repeating: 0, count: frames * stft.binCount)
        var reconstructed = [Float](repeating: 0, count: samples.count)

        for frameIndex in 0..<frames {
            let offset = frameIndex * stft.binCount
            stft.forward(
                samples: samples,
                frameStart: frameIndex * stft.hopSize,
                real: &real,
                imag: &imaginary,
                offset: offset
            )
            let frame = stft.inverse(real: real, imag: imaginary, offset: offset)
            let start = frameIndex * stft.hopSize
            for sampleIndex in 0..<stft.frameSize {
                reconstructed[start + sampleIndex] += frame[sampleIndex]
            }
        }

        let interior = stft.frameSize..<(samples.count - stft.frameSize)
        let maxError = interior.reduce(Float(0)) {
            max($0, abs(reconstructed[$1] - samples[$1]))
        }
        #expect(maxError < 1e-4)
    }

    /// Deterministic broadband noise. Seeded so a failure is reproducible.
    static func noise(count: Int, seed: UInt64 = 0xCAFE_BABE_DEAD_BEEF, amplitude: Float = 0.3) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * amplitude
        }
    }
}
