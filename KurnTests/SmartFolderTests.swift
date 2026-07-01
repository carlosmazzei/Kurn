//
//  SmartFolderTests.swift
//  KurnTests
//
//  Exercises SmartFolder persistence and dynamic filtering.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SmartFolderTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func smartFolderStoresAndReturnsFilter() throws {
        let context = makeContext()
        var filter = MeetingFilter()
        filter.dateRange = .today
        filter.hasSummary = true
        let smartFolder = SmartFolder(name: "Done today", filter: filter)
        context.insert(smartFolder)
        try context.save()

        let descriptor = FetchDescriptor<SmartFolder>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.filter.dateRange == .today)
        #expect(fetched.first?.filter.hasSummary == true)
    }

    @Test func smartFolderMatchesMeetingsByTag() throws {
        let context = makeContext()
        let tag = Kurn.Tag(name: "Work")
        let matching = Meeting(title: "Standup")
        let other = Meeting(title: "Personal")
        context.insert(tag)
        context.insert(matching)
        context.insert(other)
        matching.tags.append(tag)
        try context.save()

        var filter = MeetingFilter()
        filter.tagIDs.insert(tag.id)
        let smartFolder = SmartFolder(name: "Work", filter: filter)
        #expect(smartFolder.meetings(matching: [matching, other]).count == 1)
        #expect(smartFolder.meetings(matching: [matching, other]).first?.id == matching.id)
    }

    @Test func smartFolderMatchesMeetingsByStatus() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Done")
        let recording = Recording(meeting: meeting, fileName: "test.m4a", duration: 10)
        recording.transcriptionStatus = .done
        context.insert(meeting)
        context.insert(recording)
        try context.save()

        var filter = MeetingFilter()
        filter.statuses.insert(.done)
        let smartFolder = SmartFolder(name: "Done", filter: filter)
        #expect(smartFolder.meetings(matching: [meeting]).count == 1)

        filter.statuses = [.failed]
        smartFolder.filter = filter
        #expect(smartFolder.meetings(matching: [meeting]).isEmpty == true)
    }

    @Test func deletingSmartFolderDoesNotDeleteMeetings() throws {
        let context = makeContext()
        let smartFolder = SmartFolder(name: "Temp")
        let meeting = Meeting(title: "Keep")
        context.insert(smartFolder)
        context.insert(meeting)
        try context.save()

        context.delete(smartFolder)
        try context.save()

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
    }
}
