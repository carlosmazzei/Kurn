//
//  PlaybackTransport.swift
//  Kurn
//
//  The arithmetic behind the player's transport controls, kept apart from
//  `AVAudioPlayer` so it can be exercised without loading audio: which speeds
//  the pill cycles through and in what order, how a seek target is clamped to
//  the file, and how a relative skip resolves to an absolute position.
//

import Foundation

enum PlaybackTransport {
    /// Speeds the user can cycle through, mirroring WhatsApp's voice-note control.
    static let rateOptions: [Float] = [1.0, 1.5, 2.0, 0.5]

    /// The speed after `rate` in `rateOptions`, wrapping around. A rate that is
    /// not one of the options (e.g. restored from an older build) restarts the
    /// cycle from the second option, as if the current speed were 1.0.
    static func nextRate(after rate: Float, options: [Float] = rateOptions) -> Float {
        let index = options.firstIndex(of: rate) ?? 0
        return options[(index + 1) % options.count]
    }

    /// `time` clamped to `0...duration`. A non-finite or negative duration
    /// clamps to zero rather than producing a NaN position.
    static func clampedPosition(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let upper = duration.isFinite ? max(0, duration) : 0
        return max(0, min(time, upper))
    }

    /// The absolute position reached by moving `interval` seconds (negative goes
    /// back) from `currentTime`, clamped to the file.
    static func skippedPosition(
        from currentTime: TimeInterval,
        by interval: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        clampedPosition(currentTime + interval, duration: duration)
    }
}
