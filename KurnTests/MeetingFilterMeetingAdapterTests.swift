//
//  MeetingFilterMeetingAdapterTests.swift
//  KurnTests
//
//  MeetingFilter's predicate logic itself is pure and tested against
//  MeetingFilterAttributes in KurnCoreTests (KurnCore is Foundation-only, no
//  SwiftData). What that test suite cannot cover is the one place SwiftData
//  actually enters the picture: the `matches(_ meeting: Meeting)` adapter
//  (`Kurn/Models/MeetingFilter+Meeting.swift`) that builds a
//  `MeetingFilterAttributes` snapshot from a real `Meeting`. This pins that
//  mapping against drift in `Meeting`'s own properties.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingFilterMeetingAdapterTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func adapterMapsTagsStatusSummaryAndDuration() throws {
        let context = makeContext()
        let work = Kurn.Tag(name: "Work")
        let meeting = Meeting(title: "Standup")
        let recording = Recording(meeting: meeting, fileName: "test.m4a", duration: 120)
        recording.transcriptionStatus = .done
        let summary = Summary(meeting: meeting, sections: [], provider: .openAI)
        context.insert(work)
        context.insert(meeting)
        context.insert(recording)
        context.insert(summary)
        meeting.tags.append(work)
        try context.save()

        var filter = MeetingFilter()
        filter.tagIDs.insert(work.id)
        filter.statuses.insert(.done)
        filter.hasSummary = true
        filter.minDuration = 60

        #expect(filter.matches(meeting) == true)

        filter.tagIDs = [UUID()]
        #expect(filter.matches(meeting) == false)
    }

    @Test func adapterExcludesMeetingFailingAnyMappedCondition() throws {
        let context = makeContext()
        let meeting = Meeting(title: "No summary yet")
        context.insert(meeting)
        try context.save()

        var filter = MeetingFilter()
        filter.hasSummary = true
        #expect(filter.matches(meeting) == false)
    }
}
