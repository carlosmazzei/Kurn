//
//  PlaybackMix.swift
//  Kurn
//
//  Pure dry/wet alignment and sum for the neural playback pre-pass.
//

import Accelerate
import Foundation

enum PlaybackMix {
    /// DPDFNet cannot emit until one complete STFT frame has arrived.
    static func mix(
        dry: [Float],
        delayedWet: [Float],
        latencyFrames: Int,
        wetMix: Float
    ) -> [Float] {
        guard !dry.isEmpty else { return [] }
        let latency = max(0, latencyFrames)
        let wetCount = max(0, delayedWet.count - latency)
        let count = min(dry.count, wetCount)
        var output = dry
        guard count > 0 else { return output }

        dry.withUnsafeBufferPointer { dryPointer in
            delayedWet.withUnsafeBufferPointer { wetPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    mixAligned(
                        dry: dryPointer.baseAddress!,
                        wet: wetPointer.baseAddress!.advanced(by: latency),
                        output: outputPointer.baseAddress!,
                        count: count,
                        wetMix: wetMix
                    )
                }
            }
        }
        return output
    }

    static func mixAligned(
        dry: UnsafePointer<Float>,
        wet: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        count: Int,
        wetMix: Float
    ) {
        guard count > 0 else { return }
        var wetScale = min(max(wetMix, 0), 1)
        var dryScale = 1 - wetScale
        vDSP_vsmsma(
            wet, 1, &wetScale,
            dry, 1, &dryScale,
            output, 1,
            vDSP_Length(count)
        )
    }
}
