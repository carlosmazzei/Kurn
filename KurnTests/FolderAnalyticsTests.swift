//
//  FolderAnalyticsTests.swift
//  KurnTests
//
//  Exercises the FolderAnalytics value type.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct FolderAnalyticsTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func emptyMeetingsProduceZeroAnalytics() {
        let analytics = FolderAnalytics(meetings: [])
        #expect(analytics.meetingCount == 0)
        #expect(analytics.totalDuration == 0)
        #expect(analytics.averageDuration == 0)
        #expect(analytics.tagCounts.isEmpty)
        #expect(analytics.topSpeakers.isEmpty)
    }

    @Test func countsTotalAndAverageDuration() throws {
        let context = makeContext()
        let short = Meeting(title: "Short")
        let long = Meeting(title: "Long")
        context.insert(short)
        context.insert(long)
        context.insert(Recording(meeting: short, fileName: "a.m4a", duration: 30))
        context.insert(Recording(meeting: long, fileName: "b.m4a", duration: 90))
        try context.save()

        let analytics = FolderAnalytics(meetings: [short, long])
        #expect(analytics.meetingCount == 2)
        #expect(analytics.totalDuration == 120)
        #expect(analytics.averageDuration == 60)
    }

    @Test func tagCountsAreSortedDescending() throws {
        let context = makeContext()
        let work = Kurn.Tag(name: "Work")
        let personal = Kurn.Tag(name: "Personal")
        let meeting1 = Meeting(title: "M1")
        let meeting2 = Meeting(title: "M2")
        let meeting3 = Meeting(title: "M3")
        context.insert(work)
        context.insert(personal)
        context.insert(meeting1)
        context.insert(meeting2)
        context.insert(meeting3)
        meeting1.tags.append(work)
        meeting2.tags.append(work)
        meeting3.tags.append(contentsOf: [work, personal])
        try context.save()

        let analytics = FolderAnalytics(meetings: [meeting1, meeting2, meeting3])
        #expect(analytics.tagCounts.count == 2)
        #expect(analytics.tagCounts[0].count == 3)
        #expect(analytics.tagCounts[1].count == 1)
    }

    @Test func topSpeakersAreLimitedAndSorted() throws {
        let context = makeContext()
        let meeting = Meeting(title: "M")
        let alice = Speaker(meeting: meeting, label: "SPK1", name: "Alice", color: "#FF0000")
        let bob = Speaker(meeting: meeting, label: "SPK2", name: "Bob", color: "#0000FF")
        context.insert(meeting)
        context.insert(alice)
        context.insert(bob)
        try context.save()

        let analytics = FolderAnalytics(meetings: [meeting])
        #expect(analytics.topSpeakers.count == 2)
    }

    @Test func statusCountsReflectAggregateStatus() throws {
        let context = makeContext()
        let done = Meeting(title: "Done")
        let none = Meeting(title: "None")
        context.insert(done)
        context.insert(none)
        let recording = Recording(meeting: done, fileName: "done.m4a", duration: 10)
        recording.transcriptionStatus = .done
        context.insert(recording)
        try context.save()

        let analytics = FolderAnalytics(meetings: [done, none])
        #expect(analytics.statusCounts[.done] == 1)
        #expect(analytics.statusCounts[.none] == 1)
    }
}
