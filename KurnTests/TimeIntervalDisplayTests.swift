//
//  TimeIntervalDisplayTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct TimeIntervalDisplayTests {

    @Test func zeroIsDisplayedAsMinutesSeconds() {
        #expect(TimeInterval(0).clockDisplay == "0:00")
    }

    @Test func secondsUnderAMinute() {
        #expect(TimeInterval(45).clockDisplay == "0:45")
    }

    @Test func minutesAndSeconds() {
        #expect(TimeInterval(125).clockDisplay == "2:05")
    }

    @Test func hoursMinutesAndSeconds() {
        #expect(TimeInterval(3725).clockDisplay == "1:02:05")
    }

    @Test func roundsToNearestSecond() {
        #expect(TimeInterval(59.6).clockDisplay == "1:00")
    }

    @Test func negativeOrNonFiniteFallsBackToZero() {
        #expect(TimeInterval(-5).clockDisplay == "0:00")
        #expect(TimeInterval.infinity.clockDisplay == "0:00")
        #expect(TimeInterval.nan.clockDisplay == "0:00")
    }
}
