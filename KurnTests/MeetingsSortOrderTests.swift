//
//  MeetingsSortOrderTests.swift
//  KurnTests
//
//  Exercises every case of `MeetingsSortOrder.apply(to:)` against a small
//  in-memory set of meetings so the meetings list ordering stays stable when
//  the preference is changed by the user.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingsSortOrderTests {

    private func makeMeetings() -> [Meeting] {
        let context = ModelContext(TestModelContainer.make())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Three meetings with deliberately different titles, dates, and total
        // durations so each sort order produces a distinct, observable ordering.
        let alpha = Meeting(title: "Alpha", createdAt: now.addingTimeInterval(-600))
        let bravo = Meeting(title: "bravo", createdAt: now.addingTimeInterval(-300))
        let charlie = Meeting(title: "Charlie", createdAt: now)
        context.insert(alpha)
        context.insert(bravo)
        context.insert(charlie)
        context.insert(Recording(meeting: alpha, fileName: "a.m4a", duration: 90))
        context.insert(Recording(meeting: bravo, fileName: "b.m4a", duration: 30))
        context.insert(Recording(meeting: charlie, fileName: "c1.m4a", duration: 60))
        context.insert(Recording(meeting: charlie, fileName: "c2.m4a", duration: 60))
        return [charlie, bravo, alpha] // matches the @Query default (newest first)
    }

    @Test func dateNewestIsIdentity() {
        let meetings = makeMeetings()
        let sorted = MeetingsSortOrder.dateNewest.apply(to: meetings)
        #expect(sorted.map(\.title) == ["Charlie", "bravo", "Alpha"])
    }

    @Test func dateOldestReversesByCreatedAt() {
        let meetings = makeMeetings()
        let sorted = MeetingsSortOrder.dateOldest.apply(to: meetings)
        #expect(sorted.map(\.title) == ["Alpha", "bravo", "Charlie"])
    }

    @Test func titleAZUsesLocalizedCaseInsensitiveOrder() {
        let meetings = makeMeetings()
        let sorted = MeetingsSortOrder.titleAZ.apply(to: meetings)
        // "Alpha" < "bravo" < "Charlie" in a case-insensitive sort.
        #expect(sorted.map(\.title) == ["Alpha", "bravo", "Charlie"])
    }

    @Test func durationLongestPrefersTotalDurationDescending() {
        let meetings = makeMeetings()
        let sorted = MeetingsSortOrder.durationLongest.apply(to: meetings)
        // Charlie 120s > Alpha 90s > bravo 30s.
        #expect(sorted.map(\.title) == ["Charlie", "Alpha", "bravo"])
    }

    @Test func durationShortestPrefersTotalDurationAscending() {
        let meetings = makeMeetings()
        let sorted = MeetingsSortOrder.durationShortest.apply(to: meetings)
        #expect(sorted.map(\.title) == ["bravo", "Alpha", "Charlie"])
    }

    @Test func allCasesArePersistableViaRawValueRoundTrip() {
        for order in MeetingsSortOrder.allCases {
            #expect(MeetingsSortOrder(rawValue: order.rawValue) == order)
        }
    }
}
