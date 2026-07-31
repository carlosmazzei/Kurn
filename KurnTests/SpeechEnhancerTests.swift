//
//  SpeechEnhancerTests.swift
//  KurnTests
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct SpeechEnhancerTests {
    @Test func dryWetRatioIsApplied() {
        let dry = [Float](repeating: 1, count: 64)
        let wet = [Float](repeating: -1, count: 64)
        let mixed = PlaybackMix.mix(
            dry: dry,
            delayedWet: wet,
            latencyFrames: 0,
            wetMix: 0.85
        )
        #expect(mixed.allSatisfy { abs($0 + 0.7) < 1e-6 })
    }

    /// Equal dry and wet 1 kHz tones cancel or ripple if the one-frame latency
    /// is not removed before summing.
    @Test func dryWetMixCompensatesTheSTFTFrameLatency() {
        let sampleRate = 24_000.0
        let latency = 480
        let enhanced = (0..<2_400).map {
            Float(sin(2 * Double.pi * 1_000 * Double($0) / sampleRate)) * 0.5
        }
        let delayedWet = [Float](repeating: 0, count: latency) + enhanced

        let mixed = PlaybackMix.mix(
            dry: enhanced,
            delayedWet: delayedWet,
            latencyFrames: latency,
            wetMix: 0.85
        )
        let wetOnly = PlaybackMix.mix(
            dry: enhanced,
            delayedWet: delayedWet,
            latencyFrames: latency,
            wetMix: 1
        )
        let mixedError = zip(mixed, enhanced).map { abs($0 - $1) }.max() ?? .infinity
        let wetError = zip(wetOnly, enhanced).map { abs($0 - $1) }.max() ?? .infinity
        #expect(mixedError < 1e-6)
        #expect(wetError < 1e-6)
    }

    @Test func missingModelReturnsNil() async {
        let enhancer = SpeechEnhancer(bundle: Bundle(for: NoModelBundleMarker.self))
        let result = await enhancer.enhance(samples: [Float](repeating: 0, count: 640))
        #expect(result == nil)
    }

    // MARK: - End to end

    /// What the pure `PlaybackMix` test above cannot reach: it is handed the very
    /// delay it then compensates, so it would pass unchanged if the renderer
    /// computed `latencyFrames` wrongly — and a wrong value comb-filters every
    /// enhanced copy, which is the one artefact the dry/wet mix exists to avoid.
    ///
    /// Here the delay is produced by the pipeline itself: 24 kHz down to the
    /// model's 16 kHz, through the enhancer's leading frame, and back up. The
    /// only assertion that can catch a mistake in that arithmetic is measuring
    /// the result's lag against the source.
    @Test func theNeuralMixLandsAlignedWithTheSource() async throws {
        let source = try Self.burstFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let mixedURL = try await Self.renderNeuralMix(
            from: source,
            enhancer: InvertingEnhancer()
        )
        let mixed = try #require(mixedURL)
        defer { try? FileManager.default.removeItem(at: mixed) }

        let dry = try Self.samples(of: source)
        let wet = try Self.samples(of: mixed)
        let peak = Self.correlationPeak(reference: dry, signal: wet, maximum: 720)

        // What this certifies is the arithmetic, not sub-millisecond alignment:
        // the two resamplers in the path carry their own filter delay, which
        // nothing compensates, so a handful of frames of residual is expected.
        // The bound is set to clear that and still fail decisively on the
        // mistake worth catching — a forgotten 16 kHz → 24 kHz conversion, 320
        // frames where 480 are needed, is 160 frames out and audible at 6.7 ms.
        #expect(abs(peak.lag) <= 64, "measured lag \(peak.lag) frames")
        // And the wet is what came out, not the dry passing through: the
        // enhancer inverts, so a correlation this negative can only be its
        // output. Without this the tolerance for a short wet tail below would
        // make an empty wet stream look perfectly aligned.
        #expect(peak.correlation < -0.5 * peak.energy)
    }

    /// A wet stream that runs out early costs its tail, not the whole pass.
    /// Three resample/enhance stages each round their frame count, so a few
    /// frames of shortfall is ordinary; reverting to DSP-only over it would
    /// discard the denoising with nothing but a log line to show for it.
    @Test func aShortWetTailKeepsTheNeuralMix() async throws {
        let source = try Self.burstFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        // Far more than rounding: a third of a second, at the model's rate.
        let mixedURL = try await Self.renderNeuralMix(
            from: source,
            enhancer: InvertingEnhancer(trimFinal: 5_000)
        )
        let mixed = try #require(mixedURL)
        defer { try? FileManager.default.removeItem(at: mixed) }

        // The output still covers the whole recording — the missing wet frames
        // are dry, not absent.
        let dryCount = try Self.samples(of: source).count
        let mixedCount = try Self.samples(of: mixed).count
        #expect(mixedCount > dryCount * 9 / 10)
    }

    // MARK: - Support

    /// Tone bursts rather than a continuous tone: a 1 kHz tone repeats every 24
    /// samples at 24 kHz, so a 480-frame misalignment would correlate perfectly
    /// and the test would prove nothing. The envelope edges are what make the
    /// correlation peak unambiguous.
    private static func burstFixture() throws -> URL {
        try AudioFixtures.wav(
            segments: [(0, 0.12), (900, 0.2), (0, 0.12), (600, 0.2), (0, 0.12)],
            sampleRate: PlaybackEnhancementRenderer.outputSampleRate,
            amplitude: 0.4
        )
    }

    private static func renderNeuralMix(
        from source: URL,
        enhancer: any SpeechEnhancing
    ) async throws -> URL? {
        var tuning = PlaybackTuning.listening
        // Wet only, so what is left to measure is the alignment and not the sum.
        tuning.wetMix = 1
        let renderer = PlaybackEnhancementRenderer(tuning: tuning, enhancer: enhancer)
        return try await renderer.renderNeuralMix(
            from: source,
            failure: AppError.audioError("test")
        )
    }

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    private struct CorrelationPeak {
        /// Positive when `signal` is late.
        var lag: Int
        /// Signed, so the enhancer's inversion is visible rather than folded away.
        var correlation: Float
        /// The reference's own energy over the same window, for scale.
        var energy: Float
    }

    /// Lag at which `signal` best matches `reference`.
    ///
    /// The window is fixed rather than growing with the overlap, so every lag is
    /// scored over identical reference samples — otherwise lag 0 would win by
    /// having more samples to sum, which is the answer being asserted.
    private static func correlationPeak(
        reference: [Float],
        signal: [Float],
        maximum: Int
    ) -> CorrelationPeak {
        let start = maximum
        let end = min(reference.count, signal.count) - maximum
        guard end > start else { return CorrelationPeak(lag: .max, correlation: 0, energy: 0) }

        var bestLag = 0
        var best = Float(0)
        var energy = Float(0)
        reference.withUnsafeBufferPointer { referencePointer in
            signal.withUnsafeBufferPointer { signalPointer in
                for index in start..<end {
                    energy += referencePointer[index] * referencePointer[index]
                }
                for lag in -maximum...maximum {
                    var sum = Float(0)
                    for index in start..<end {
                        sum += referencePointer[index] * signalPointer[index + lag]
                    }
                    if abs(sum) > abs(best) {
                        best = sum
                        bestLag = lag
                    }
                }
            }
        }
        return CorrelationPeak(lag: bestLag, correlation: best, energy: energy)
    }
}

/// Stands in for the model behind the same protocol the renderer uses, with the
/// real `StreamState`'s emission contract: one leading frame of silence, then
/// the samples.
///
/// It inverts rather than passing through, because an identity enhancer is
/// indistinguishable from no enhancement at all — and the mix now tolerates a
/// wet stream that ends early, so an empty one would otherwise read as a
/// perfectly aligned result.
private actor InvertingEnhancer: SpeechEnhancing {
    /// 20 ms at 16 kHz, the window both candidate models use.
    static let frameSize = 320
    static let modelSampleRate = 16_000.0

    private let trimFinal: Int
    private var primed: Set<UUID> = []

    init(trimFinal: Int = 0) {
        self.trimFinal = trimFinal
    }

    func beginStream() -> UUID? { UUID() }

    func enhance(samples: [Float], streamID: UUID, isFinal: Bool) -> [Float]? {
        var output: [Float] = []
        if primed.insert(streamID).inserted {
            output.append(contentsOf: repeatElement(0, count: Self.frameSize))
        }
        output.append(contentsOf: samples.map { -$0 })
        if isFinal {
            primed.remove(streamID)
            output.removeLast(min(trimFinal, output.count))
        }
        return output
    }

    func endStream(_ streamID: UUID) {
        primed.remove(streamID)
    }

    func latencyFrames(at sampleRate: Double) -> Int? {
        Int((Double(Self.frameSize) * sampleRate / Self.modelSampleRate).rounded())
    }

    func enhance(samples: [Float]) -> [Float]? { samples.map { -$0 } }
}

private final class NoModelBundleMarker {}
