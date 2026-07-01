//
//  TagTests.swift
//  KurnTests
//
//  Exercises the Tag model and its many-to-many relationship with Meeting.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TagTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func defaultColorIsPaletteDefault() {
        let tag = Kurn.Tag(name: "Important")
        #expect(tag.colorHex == TagColorPalette.default)
    }

    @Test func assigningTagPopulatesInverseMeetings() throws {
        let context = makeContext()
        let tag = Kurn.Tag(name: "Work")
        let meeting = Meeting(title: "Standup")
        context.insert(tag)
        context.insert(meeting)
        meeting.tags.append(tag)
        try context.save()

        #expect(tag.meetings.count == 1)
        #expect(tag.meetings.first?.persistentModelID == meeting.persistentModelID)
    }

    @Test func meetingCanHaveMultipleTags() throws {
        let context = makeContext()
        let work = Kurn.Tag(name: "Work")
        let urgent = Kurn.Tag(name: "Urgent")
        let meeting = Meeting(title: "Review")
        context.insert(work)
        context.insert(urgent)
        context.insert(meeting)
        meeting.tags.append(contentsOf: [work, urgent])
        try context.save()

        #expect(meeting.tags.count == 2)
    }

    @Test func deletingTagDetachesFromMeetings() throws {
        let context = makeContext()
        let tag = Kurn.Tag(name: "Temp")
        let meeting = Meeting(title: "Draft")
        context.insert(tag)
        context.insert(meeting)
        meeting.tags.append(tag)
        try context.save()

        context.delete(tag)
        try context.save()

        let descriptor = FetchDescriptor<Meeting>()
        let remaining = try context.fetch(descriptor)
        #expect(remaining.count == 1)
        #expect(remaining.first?.tags.isEmpty == true)
    }

    @Test func deletingMeetingDetachesFromTag() throws {
        let context = makeContext()
        let tag = Kurn.Tag(name: "Work")
        let meeting = Meeting(title: "Standup")
        context.insert(tag)
        context.insert(meeting)
        meeting.tags.append(tag)
        try context.save()

        context.delete(meeting)
        try context.save()

        let descriptor = FetchDescriptor<Kurn.Tag>()
        let remaining = try context.fetch(descriptor)
        #expect(remaining.count == 1)
        #expect(remaining.first?.meetings.isEmpty == true)
    }
}
