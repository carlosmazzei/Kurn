//
//  PlaybackMix.swift
//  Kurn
//
//  Pure dry/wet alignment and sum for the neural playback pre-pass.
//

import Accelerate

enum PlaybackMix {
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
