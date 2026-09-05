//
//  PlaybackScrubberLayout.swift
//  Kurn
//
//  The arithmetic behind `SegmentPlaybackScrubber`: slider bounds, the
//  clamped playhead, and where the floating time marker sits so it never
//  overhangs either edge.
//

import Foundation

struct PlaybackScrubberLayout: Equatable {
    static let markerWidth: Double = 54

    let currentTime: TimeInterval
    let duration: TimeInterval

    var playableDuration: TimeInterval { max(duration, 0) }

    /// A zero-length or unknown duration still needs a non-degenerate slider.
    var sliderUpperBound: TimeInterval { max(playableDuration, 1) }

    var boundedCurrentTime: TimeInterval {
        min(max(currentTime, 0), sliderUpperBound)
    }

    /// Playhead position as 0…1 of the slider range.
    var fraction: Double {
        sliderUpperBound > 0 ? boundedCurrentTime / sliderUpperBound : 0
    }

    /// Horizontal centre of the time marker within a track `width` points
    /// wide, kept inside the track so the marker's half-width never clips.
    func markerCenterX(trackWidth width: Double) -> Double {
        let half = Self.markerWidth / 2
        return min(max(half, width * fraction), max(half, width - half))
    }

    static func rateLabel(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }
}
