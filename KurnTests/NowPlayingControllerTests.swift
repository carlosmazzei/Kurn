//
//  NowPlayingControllerTests.swift
//  KurnTests
//
//  The metadata contract with the system.
//
//  Only the dictionary is asserted here. Whether the Lock Screen, CarPlay or an
//  AirPods stem press actually reach the handlers cannot be simulated — a test
//  host can neither lock the screen nor take a call — so that half stays
//  device-verified, and this covers the part that is deterministic: what gets
//  published, and what is deliberately left out.
//

import Foundation
import MediaPlayer
import Testing
@testable import Kurn

/// `NowPlayingController` and `AudioPlayerService` are both `@MainActor`, and so
/// are their static members.
@MainActor
struct NowPlayingControllerTests {

    @Test func publishesTitleDurationAndRate() {
        let info = NowPlayingController.info(
            title: "Weekly planning",
            subtitle: "12 Mar 2026 at 09:30",
            duration: 3600,
            position: 125,
            rate: 1.5
        )

        #expect(info[MPMediaItemPropertyTitle] as? String == "Weekly planning")
        #expect(info[MPMediaItemPropertyArtist] as? String == "12 Mar 2026 at 09:30")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 3600)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 125)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 1.5)
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
    }

    /// A paused player publishes rate 0 rather than dropping out of Now Playing:
    /// the system extrapolates position from the rate, so a stale non-zero rate
    /// would make the Lock Screen keep counting over silence.
    @Test func pausedPublishesAZeroRate() {
        let info = NowPlayingController.info(
            title: "Weekly planning",
            subtitle: nil,
            duration: 600,
            position: 42,
            rate: 0
        )
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 0)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 42)
    }

    /// Blank metadata is omitted, not published empty — an empty title renders as
    /// a blank row on the Lock Screen instead of falling back to the app name.
    @Test func omitsEmptyMetadata() {
        let info = NowPlayingController.info(
            title: nil,
            subtitle: "",
            duration: 60,
            position: 0,
            rate: 1
        )
        #expect(info[MPMediaItemPropertyTitle] == nil)
        #expect(info[MPMediaItemPropertyArtist] == nil)
    }

    @Test func clampsPositionIntoTheFile() {
        let past = NowPlayingController.info(
            title: nil, subtitle: nil, duration: 100, position: 500, rate: 1
        )
        #expect(past[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 100)

        let negative = NowPlayingController.info(
            title: nil, subtitle: nil, duration: 100, position: -5, rate: 1
        )
        #expect(negative[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 0)
    }

    @Test func skipIntervalMatchesThePlayer() {
        #expect(AudioPlayerService.skipInterval == NowPlayingController.skipInterval)
        #expect(NowPlayingController.skipInterval == 15)
    }
}
