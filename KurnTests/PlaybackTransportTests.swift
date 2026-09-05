//
//  PlaybackTransportTests.swift
//  KurnTests
//
//  The player's transport arithmetic without an `AVAudioPlayer`: the speed
//  cycle (order, wrap-around, unknown rate), seek clamping to the file, and
//  relative skips in both directions — plus the constants the UI and the Lock
//  Screen share.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
@Suite("PlaybackTransport")
struct PlaybackTransportTests {

    @Test func rateOptionsMatchTheVoiceNoteCycleAndArePublishedByThePlayer() {
        #expect(PlaybackTransport.rateOptions == [1.0, 1.5, 2.0, 0.5])
        #expect(AudioPlayerService.rateOptions == PlaybackTransport.rateOptions)
    }

    @Test func skipIntervalIsSharedWithTheLockScreen() {
        #expect(AudioPlayerService.skipInterval == NowPlayingController.skipInterval)
        #expect(AudioPlayerService.skipInterval == 15)
    }

    @Test func cyclingVisitsEverySpeedInOrderAndWraps() {
        var rate: Float = 1.0
        var visited: [Float] = []
        for _ in PlaybackTransport.rateOptions {
            rate = PlaybackTransport.nextRate(after: rate)
            visited.append(rate)
        }
        #expect(visited == [1.5, 2.0, 0.5, 1.0])
    }

    @Test func unknownRateRestartsTheCycleAsIfAtNormalSpeed() {
        #expect(PlaybackTransport.nextRate(after: 1.25) == 1.5)
        #expect(PlaybackTransport.nextRate(after: 0) == 1.5)
    }

    @Test func singleOptionCyclesToItself() {
        #expect(PlaybackTransport.nextRate(after: 1.0, options: [1.0]) == 1.0)
    }

    @Test func seekIsClampedToTheFile() {
        #expect(PlaybackTransport.clampedPosition(30, duration: 120) == 30)
        #expect(PlaybackTransport.clampedPosition(-5, duration: 120) == 0)
        #expect(PlaybackTransport.clampedPosition(500, duration: 120) == 120)
        #expect(PlaybackTransport.clampedPosition(0, duration: 120) == 0)
        #expect(PlaybackTransport.clampedPosition(120, duration: 120) == 120)
    }

    @Test func degenerateDurationsClampToZero() {
        #expect(PlaybackTransport.clampedPosition(10, duration: 0) == 0)
        #expect(PlaybackTransport.clampedPosition(10, duration: -3) == 0)
        #expect(PlaybackTransport.clampedPosition(10, duration: .nan) == 0)
        #expect(PlaybackTransport.clampedPosition(10, duration: .infinity) == 0)
    }

    @Test func skipsMoveRelativeToTheCurrentPositionInBothDirections() {
        #expect(PlaybackTransport.skippedPosition(from: 60, by: 15, duration: 120) == 75)
        #expect(PlaybackTransport.skippedPosition(from: 60, by: -15, duration: 120) == 45)
        #expect(PlaybackTransport.skippedPosition(from: 60, by: 0, duration: 120) == 60)
    }

    @Test func skipsAreClampedAtBothEnds() {
        #expect(PlaybackTransport.skippedPosition(from: 5, by: -15, duration: 120) == 0)
        #expect(PlaybackTransport.skippedPosition(from: 110, by: 15, duration: 120) == 120)
        #expect(
            PlaybackTransport.skippedPosition(from: 110, by: AudioPlayerService.skipInterval, duration: 120) == 120
        )
    }
}
