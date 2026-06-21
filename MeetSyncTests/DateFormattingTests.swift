//
//  DateFormattingTests.swift
//  MeetSyncTests
//

import Foundation
import Testing
@testable import MeetSync

struct DateFormattingTests {

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        time: DateComponents
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0
        )
        return calendar.date(from: components)!
    }

    @Test func isoDayFormatsAsYearMonthDay() {
        let date = makeDate(year: 2025, month: 6, day: 16, time: DateComponents(hour: 9, minute: 30, second: 0))
        // isoDay uses the current TimeZone via DateFormatter defaults, so only
        // assert the shape rather than an exact value to stay TZ-independent.
        let value = date.isoDay
        #expect(value.count == 10)
        #expect(value.filter { $0 == "-" }.count == 2)
    }

    @Test func fileTimestampHasExpectedShape() {
        let date = makeDate(year: 2025, month: 6, day: 16, time: DateComponents(hour: 9, minute: 30, second: 12))
        let value = date.fileTimestamp
        // yyyyMMdd-HHmmss
        #expect(value.count == 15)
        #expect(value.contains("-"))
    }

    @Test func meetingDisplayIsNonEmpty() {
        let date = makeDate(year: 2025, month: 6, day: 16, time: DateComponents(hour: 9, minute: 30, second: 0))
        #expect(!date.meetingDisplay.isEmpty)
    }
}
