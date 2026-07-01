//
//  MeetingFilterTests.swift
//  KurnTests
//
//  Exercises the predicate logic in MeetingFilter: date range, tags, status,
//  summary presence, and duration bounds.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingFilterTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func defaultFilterMatchesEverything() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Anything")
        context.insert(meeting)
        try context.save()

        let filter = MeetingFilter()
        #expect(filter.matches(meeting) == true)
        #expect(filter.isActive == false)
    }

    @Test func dateRangeTodayFiltersByCreatedAt() throws {
        let context = makeContext()
        let today = Meeting(title: "Today", createdAt: Date())
        let lastWeek = Meeting(title: "Old", createdAt: Date().addingTimeInterval(-7 * 24 * 3600))
        context.insert(today)
        context.insert(lastWeek)
        try context.save()

        var filter = MeetingFilter()
        filter.dateRange = .today
        #expect(filter.matches(today) == true)
        #expect(filter.matches(lastWeek) == false)
    }

    @Test func tagFilterMatchesMeetingsWithTag() throws {
        let context = makeContext()
        let work = Kurn.Tag(name: "Work")
        let meeting = Meeting(title: "Standup")
        context.insert(work)
        context.insert(meeting)
        meeting.tags.append(work)
        try context.save()

        var filter = MeetingFilter()
        filter.tagIDs.insert(work.id)
        #expect(filter.matches(meeting) == true)
        #expect(filter.isActive == true)
    }

    @Test func tagFilterExcludesMeetingWithoutTag() throws {
        let context = makeContext()
        let work = Kurn.Tag(name: "Work")
        let tagged = Meeting(title: "Tagged")
        let untagged = Meeting(title: "Untagged")
        context.insert(work)
        context.insert(tagged)
        context.insert(untagged)
        tagged.tags.append(work)
        try context.save()

        var filter = MeetingFilter()
        filter.tagIDs.insert(work.id)
        #expect(filter.matches(tagged) == true)
        #expect(filter.matches(untagged) == false)
    }

    @Test func statusFilterMatchesAggregateStatus() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Done")
        let recording = Recording(meeting: meeting, fileName: "test.m4a", duration: 10)
        recording.transcriptionStatus = .done
        context.insert(meeting)
        context.insert(recording)
        try context.save()

        var filter = MeetingFilter()
        filter.statuses.insert(.done)
        #expect(filter.matches(meeting) == true)

        filter.statuses = [.failed]
        #expect(filter.matches(meeting) == false)
    }

    @Test func hasSummaryFilter() throws {
        let context = makeContext()
        let withSummary = Meeting(title: "With Summary")
        let withoutSummary = Meeting(title: "Without Summary")
        let summary = Summary(meeting: withSummary, sections: [], provider: .openAI)
        context.insert(withSummary)
        context.insert(withoutSummary)
        context.insert(summary)
        try context.save()

        var filter = MeetingFilter()
        filter.hasSummary = true
        #expect(filter.matches(withSummary) == true)
        #expect(filter.matches(withoutSummary) == false)

        filter.hasSummary = false
        #expect(filter.matches(withSummary) == false)
        #expect(filter.matches(withoutSummary) == true)
    }

    @Test func durationBoundsFilter() throws {
        let context = makeContext()
        let short = Meeting(title: "Short")
        let long = Meeting(title: "Long")
        context.insert(short)
        context.insert(long)
        let shortRecording = Recording(meeting: short, fileName: "short.m4a", duration: 30)
        let longRecording = Recording(meeting: long, fileName: "long.m4a", duration: 300)
        context.insert(shortRecording)
        context.insert(longRecording)
        try context.save()

        var filter = MeetingFilter()
        filter.minDuration = 60
        #expect(filter.matches(short) == false)
        #expect(filter.matches(long) == true)

        filter.minDuration = nil
        filter.maxDuration = 60
        #expect(filter.matches(short) == true)
        #expect(filter.matches(long) == false)
    }

    @Test func activeCountReflectsNonDefaultConditions() throws {
        let context = makeContext()
        let tag = Kurn.Tag(name: "Work")
        context.insert(tag)
        try context.save()

        var filter = MeetingFilter()
        #expect(filter.activeCount == 0)

        filter.dateRange = .today
        #expect(filter.activeCount == 1)

        filter.tagIDs.insert(tag.id)
        #expect(filter.activeCount == 2)
    }
}
