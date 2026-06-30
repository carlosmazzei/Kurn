//
//  FolderRelationshipTests.swift
//  KurnTests
//
//  Exercises the `Folder` model end-to-end against a real in-memory
//  `ModelContainer`: assigning meetings, deleting a folder (.nullify rule),
//  the parent/children self-relation for future subfolder UI, and Inbox vs.
//  folder bucket semantics.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct FolderRelationshipTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    // MARK: - Defaults

    @Test func defaultFolderHasFolderFillIconAndAccentColor() {
        let folder = Folder(name: "Work")
        #expect(folder.iconName == "folder.fill")
        #expect(folder.colorHex == "#5E5CE6")
        #expect(folder.isRoot == true)
    }

    // MARK: - Meeting <-> Folder inverse

    @Test func assigningFolderPopulatesInverseMeetings() throws {
        let context = makeContext()
        let folder = Folder(name: "Work")
        let meeting = Meeting(title: "Standup")
        context.insert(folder)
        context.insert(meeting)
        meeting.folder = folder
        try context.save()
        #expect(folder.meetings.count == 1)
        #expect(folder.meetings.first?.persistentModelID == meeting.persistentModelID)
    }

    @Test func deletingFolderDetachesMeetingsButKeepsThem() throws {
        let context = makeContext()
        let folder = Folder(name: "Work")
        let meeting = Meeting(title: "Standup")
        context.insert(folder)
        context.insert(meeting)
        meeting.folder = folder
        try context.save()

        context.delete(folder)
        try context.save()

        // The meeting itself should still be present in the store.
        let descriptor = FetchDescriptor<Meeting>()
        let remaining = try context.fetch(descriptor)
        #expect(remaining.count == 1)
        #expect(remaining.first?.folder == nil)
    }

    // MARK: - Subfolder self-relation

    @Test func deletingParentFolderMakesChildrenRoot() throws {
        let context = makeContext()
        let parent = Folder(name: "Parent")
        context.insert(parent)
        let childA = Folder(name: "ChildA", parent: parent)
        let childB = Folder(name: "ChildB", parent: parent)
        context.insert(childA)
        context.insert(childB)
        try context.save()

        // Sanity-check the inverse before mutating.
        #expect(parent.children.count == 2)
        #expect(childA.isRoot == false)

        context.delete(parent)
        try context.save()

        let descriptor = FetchDescriptor<Folder>()
        let remaining = try context.fetch(descriptor)
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.parent == nil })
    }

    // MARK: - LibrarySelection predicate

    @Test func folderSelectionMatchesOnlyMeetingsInThatFolder() throws {
        let context = makeContext()
        let work = Folder(name: "Work")
        let personal = Folder(name: "Personal")
        context.insert(work)
        context.insert(personal)
        let inWork = Meeting(title: "Standup")
        let inPersonal = Meeting(title: "Therapy")
        let inInbox = Meeting(title: "Unfiled")
        context.insert(inWork)
        context.insert(inPersonal)
        context.insert(inInbox)
        inWork.folder = work
        inPersonal.folder = personal
        try context.save()

        let workSelection = LibrarySelection.folder(work.persistentModelID)
        #expect(workSelection.contains(inWork) == true)
        #expect(workSelection.contains(inPersonal) == false)
        #expect(workSelection.contains(inInbox) == false)
    }

    @Test func folderSelectionExcludesArchivedMeetings() throws {
        let context = makeContext()
        let work = Folder(name: "Work")
        context.insert(work)
        let live = Meeting(title: "Live")
        let archived = Meeting(title: "Old")
        context.insert(live)
        context.insert(archived)
        live.folder = work
        archived.folder = work
        archived.archivedAt = Date()
        try context.save()

        let workSelection = LibrarySelection.folder(work.persistentModelID)
        #expect(workSelection.contains(live) == true)
        // Archived meeting is still attached to the folder in the store but is
        // hidden from the folder view — the Archive bucket is the only way to
        // reach it.
        #expect(workSelection.contains(archived) == false)
        #expect(MeetingsLibraryBucket.archive.contains(archived) == true)
    }

    @Test func inboxBucketShowsOnlyMeetingsWithoutFolder() throws {
        let context = makeContext()
        let work = Folder(name: "Work")
        context.insert(work)
        let filed = Meeting(title: "Filed")
        let unfiled = Meeting(title: "Unfiled")
        context.insert(filed)
        context.insert(unfiled)
        filed.folder = work
        try context.save()
        #expect(MeetingsLibraryBucket.inbox.contains(filed) == false)
        #expect(MeetingsLibraryBucket.inbox.contains(unfiled) == true)
    }

    @Test func allBucketStillIncludesFiledMeetings() throws {
        let context = makeContext()
        let work = Folder(name: "Work")
        context.insert(work)
        let filed = Meeting(title: "Filed")
        let unfiled = Meeting(title: "Unfiled")
        context.insert(filed)
        context.insert(unfiled)
        filed.folder = work
        try context.save()
        #expect(MeetingsLibraryBucket.all.contains(filed) == true)
        #expect(MeetingsLibraryBucket.all.contains(unfiled) == true)
    }
}
