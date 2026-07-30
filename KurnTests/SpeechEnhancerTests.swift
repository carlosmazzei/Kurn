//
//  SpeechEnhancerTests.swift
//  KurnTests
//

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
}

private final class NoModelBundleMarker {}
