//
//  PlaybackScrubberLayoutTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct PlaybackScrubberLayoutTests {

    @Test func negativeOrZeroDurationStillYieldsAUsableSlider() {
        let negative = PlaybackScrubberLayout(currentTime: 0, duration: -5)
        #expect(negative.playableDuration == 0)
        #expect(negative.sliderUpperBound == 1)
        #expect(negative.fraction == 0)

        let zero = PlaybackScrubberLayout(currentTime: 3, duration: 0)
        #expect(zero.playableDuration == 0)
        #expect(zero.sliderUpperBound == 1)
        #expect(zero.boundedCurrentTime == 1)
    }

    @Test func shortDurationsAreStretchedToAtLeastOneSecond() {
        let layout = PlaybackScrubberLayout(currentTime: 0.25, duration: 0.5)
        #expect(layout.playableDuration == 0.5)
        #expect(layout.sliderUpperBound == 1)
        #expect(layout.fraction == 0.25)
    }

    @Test func currentTimeIsClampedToTheSliderRange() {
        #expect(PlaybackScrubberLayout(currentTime: -3, duration: 60).boundedCurrentTime == 0)
        #expect(PlaybackScrubberLayout(currentTime: 30, duration: 60).boundedCurrentTime == 30)
        #expect(PlaybackScrubberLayout(currentTime: 75, duration: 60).boundedCurrentTime == 60)
        #expect(PlaybackScrubberLayout(currentTime: 75, duration: 60).fraction == 1)
    }

    @Test func markerFollowsThePlayheadInsideTheTrack() {
        let layout = PlaybackScrubberLayout(currentTime: 30, duration: 60)
        #expect(layout.markerCenterX(trackWidth: 300) == 150)
    }

    @Test func markerNeverOverhangsEitherEdge() {
        let half = PlaybackScrubberLayout.markerWidth / 2
        #expect(PlaybackScrubberLayout(currentTime: 0, duration: 60).markerCenterX(trackWidth: 300) == half)
        #expect(PlaybackScrubberLayout(currentTime: 1, duration: 60).markerCenterX(trackWidth: 300) == half)
        #expect(PlaybackScrubberLayout(currentTime: 60, duration: 60).markerCenterX(trackWidth: 300) == 300 - half)
        #expect(PlaybackScrubberLayout(currentTime: 59.9, duration: 60).markerCenterX(trackWidth: 300) == 300 - half)
    }

    @Test func markerOnANarrowTrackStaysAtTheLeadingHalfWidth() {
        let half = PlaybackScrubberLayout.markerWidth / 2
        #expect(PlaybackScrubberLayout(currentTime: 60, duration: 60).markerCenterX(trackWidth: 20) == half)
        #expect(PlaybackScrubberLayout(currentTime: 0, duration: 60).markerCenterX(trackWidth: 0) == half)
    }

    @Test func rateLabelDropsTrailingZeros() {
        #expect(PlaybackScrubberLayout.rateLabel(1.0) == "1×")
        #expect(PlaybackScrubberLayout.rateLabel(1.5) == "1.5×")
        #expect(PlaybackScrubberLayout.rateLabel(2.0) == "2×")
        #expect(PlaybackScrubberLayout.rateLabel(0.5) == "0.5×")
    }
}
