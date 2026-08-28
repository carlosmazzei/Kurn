//
//  MeetingFilterTests.swift
//  KurnCoreTests
//
//  Exercises the predicate logic in MeetingFilter: date range, tags, status,
//  summary presence, and duration bounds — entirely over `MeetingFilterAttributes`
//  snapshots, with no SwiftData involved. The SwiftData-facing half (building a
//  snapshot from a real `Meeting`) is covered separately by
//  `KurnTests/MeetingFilterMeetingAdapterTests.swift`.
//

import Foundation
import Testing
@testable import KurnCore

struct MeetingFilterTests {

    private func attributes(
        tagIDs: Set<UUID> = [],
        status: TranscriptionStatus = .none,
        createdAt: Date = Date(),
        hasSummary: Bool = false,
        totalDuration: TimeInterval = 0
    ) -> MeetingFilterAttributes {
        MeetingFilterAttributes(
            tagIDs: tagIDs,
            status: status,
            createdAt: createdAt,
            hasSummary: hasSummary,
            totalDuration: totalDuration
        )
    }

    @Test func defaultFilterMatchesEverything() {
        let filter = MeetingFilter()
        #expect(filter.matches(attributes()) == true)
        #expect(filter.isActive == false)
    }

    @Test func dateRangeTodayFiltersByCreatedAt() {
        let today = attributes(createdAt: Date())
        let lastWeek = attributes(createdAt: Date().addingTimeInterval(-7 * 24 * 3600))

        var filter = MeetingFilter()
        filter.dateRange = .today
        #expect(filter.matches(today) == true)
        #expect(filter.matches(lastWeek) == false)
    }

    @Test func tagFilterMatchesMeetingsWithTag() {
        let workTagID = UUID()
        let tagged = attributes(tagIDs: [workTagID])

        var filter = MeetingFilter()
        filter.tagIDs.insert(workTagID)
        #expect(filter.matches(tagged) == true)
        #expect(filter.isActive == true)
    }

    @Test func tagFilterExcludesMeetingWithoutTag() {
        let workTagID = UUID()
        let tagged = attributes(tagIDs: [workTagID])
        let untagged = attributes(tagIDs: [])

        var filter = MeetingFilter()
        filter.tagIDs.insert(workTagID)
        #expect(filter.matches(tagged) == true)
        #expect(filter.matches(untagged) == false)
    }

    @Test func statusFilterMatchesAggregateStatus() {
        let meeting = attributes(status: .done)

        var filter = MeetingFilter()
        filter.statuses.insert(.done)
        #expect(filter.matches(meeting) == true)

        filter.statuses = [.failed]
        #expect(filter.matches(meeting) == false)
    }

    @Test func hasSummaryFilter() {
        let withSummary = attributes(hasSummary: true)
        let withoutSummary = attributes(hasSummary: false)

        var filter = MeetingFilter()
        filter.hasSummary = true
        #expect(filter.matches(withSummary) == true)
        #expect(filter.matches(withoutSummary) == false)

        filter.hasSummary = false
        #expect(filter.matches(withSummary) == false)
        #expect(filter.matches(withoutSummary) == true)
    }

    @Test func durationBoundsFilter() {
        let short = attributes(totalDuration: 30)
        let long = attributes(totalDuration: 300)

        var filter = MeetingFilter()
        filter.minDuration = 60
        #expect(filter.matches(short) == false)
        #expect(filter.matches(long) == true)

        filter.minDuration = nil
        filter.maxDuration = 60
        #expect(filter.matches(short) == true)
        #expect(filter.matches(long) == false)
    }

    @Test func activeCountReflectsNonDefaultConditions() {
        var filter = MeetingFilter()
        #expect(filter.activeCount == 0)

        filter.dateRange = .today
        #expect(filter.activeCount == 1)

        filter.tagIDs.insert(UUID())
        #expect(filter.activeCount == 2)
    }
}
