//
//  DaySectionsTests.swift
//  KurnCoreTests
//
//  Covers the meetings list's day grouping: same-day items share a section,
//  different days split, order is preserved, and empty input yields no
//  sections.
//

import Foundation
import Testing
@testable import KurnCore

struct DaySectionsTests {

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents(year: year, month: month, day: day, hour: hour)
        components.calendar = .current
        return components.date ?? Date()
    }

    @Test func sameDayMeetingsShareOneSection() {
        let items = [day(2026, 11, 21, 9), day(2026, 11, 21, 18)]
        let sections = DaySections.group(items, date: { $0 })
        #expect(sections.count == 1)
        #expect(sections[0].items == items)
    }

    @Test func differentDaysProduceOrderedSections() {
        let items = [day(2026, 11, 21), day(2026, 11, 20), day(2026, 11, 21, 23)]
        let sections = DaySections.group(items, date: { $0 })
        #expect(sections.count == 2)
        #expect(sections[0].items == [items[0], items[2]])
        #expect(sections[1].items == [items[1]])
    }

    @Test func emptyInputProducesNoSections() {
        #expect(DaySections.group([Date](), date: { $0 }).isEmpty)
    }
}
