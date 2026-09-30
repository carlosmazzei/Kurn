//
//  MeetingLibraryTests.swift
//  KurnTests
//
//  `MeetingLibrary` took over the library mutations Views used to make
//  directly and those `MeetingsViewModel` made for them. These pin the rules
//  that moved with them: titles and names are trimmed, tag names are unique
//  case-insensitively, deletes that own files go through the journal and
//  remove those files, and `.nullify` relationships detach rather than delete.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingLibraryTests {

    private func makeLibrary() -> (MeetingLibrary, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        return (MeetingLibrary(context: context), context)
    }

    // MARK: - Meetings

    @Test func createMeetingUsesTrimmedTitle() throws {
        let (library, _) = makeLibrary()
        let meeting = try library.createMeeting(title: "  Sprint Planning  ")
        #expect(meeting.title == "Sprint Planning")
    }

    @Test func createMeetingFallsBackToDefaultTitleWhenBlank() throws {
        let (library, _) = makeLibrary()
        let meeting = try library.createMeeting(title: "   ")
        #expect(!meeting.title.isEmpty)
        #expect(meeting.title != "   ")
    }

    @Test func createMeetingTreatsNewlineAndTabOnlyTitleAsBlank() throws {
        let (library, _) = makeLibrary()
        let meeting = try library.createMeeting(title: "\n\t  ")
        #expect(!meeting.title.isEmpty)
        #expect(!meeting.title.contains("\n"))
    }

    @Test func createMeetingPersistsLanguageAndNotes() throws {
        let (library, _) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup", notes: "Daily sync", language: .portuguese)
        #expect(meeting.notes == "Daily sync")
        #expect(meeting.language == .portuguese)
    }

    @Test func createMeetingInsertsIntoContext() throws {
        let (library, context) = makeLibrary()
        try library.createMeeting(title: "Standup")
        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.count == 1)
    }

    @Test func deleteMeetingRemovesItFromContext() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        try library.deleteMeeting(meeting)
        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.isEmpty)
    }

    // MARK: - Audio and photo file cleanup

    /// Write a placeholder file in Documents and return its name + URL.
    private func makeFile(extension ext: String = "m4a") throws -> (name: String, url: URL) {
        let name = "test_\(UUID().uuidString).\(ext)"
        let url = AudioFileStore.documentsURL.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return (name, url)
    }

    @Test func deleteRecordingRemovesAudioFileAndModel() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }
        #expect(FileManager.default.fileExists(atPath: file.url.path))

        let recording = Recording(meeting: meeting, fileName: file.name, duration: 12)
        context.insert(recording)
        try context.save()

        try library.deleteRecording(recording)

        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        let remaining = try context.fetch(FetchDescriptor<Recording>())
        #expect(remaining.isEmpty)
    }

    @Test func deleteMeetingRemovesEveryRecordingAudioFile() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let first = try makeFile()
        let second = try makeFile()
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }

        context.insert(Recording(meeting: meeting, fileName: first.name, duration: 5))
        context.insert(Recording(meeting: meeting, fileName: second.name, duration: 6))
        try context.save()

        try library.deleteMeeting(meeting)

        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        let remaining = try context.fetch(FetchDescriptor<Recording>())
        #expect(remaining.isEmpty)
    }

    @Test func deletePhotoRemovesItsFileAndKeepsTheRecording() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 5)
        context.insert(recording)
        let file = try makeFile(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: file.url) }
        let photo = MeetingPhoto(recording: recording, fileName: file.name, capturedAt: 2)
        context.insert(photo)
        try context.save()

        try library.deletePhoto(photo)

        #expect(try context.fetch(FetchDescriptor<MeetingPhoto>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func deleteSummaryKeepsTheMeetingsOtherSummaries() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let general = Summary(meeting: meeting, templateName: "General", provider: .openAI)
        let standup = Summary(meeting: meeting, templateName: "Standup", provider: .openAI)
        context.insert(general)
        context.insert(standup)
        try context.save()

        try library.deleteSummary(general)

        let remaining = try context.fetch(FetchDescriptor<Summary>())
        #expect(remaining.map(\.templateName) == ["Standup"])
    }

    // MARK: - Tags

    @Test func createTagTrimsAndIgnoresBlankNames() throws {
        let (library, context) = makeLibrary()
        #expect(try library.createTag(named: "   ") == nil)
        let tag = try library.createTag(named: "  Roadmap ")
        #expect(tag?.name == "Roadmap")
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).count == 1)
    }

    @Test func createTagIsCaseInsensitivelyUnique() throws {
        let (library, context) = makeLibrary()
        try library.createTag(named: "Roadmap")
        #expect(try library.createTag(named: "roadmap") == nil)
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).count == 1)
    }

    @Test func attachTagReusesAnExistingTagOfTheSameName() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let existing = try #require(try library.createTag(named: "Roadmap"))

        try library.attachTag(named: "ROADMAP", to: meeting)
        try library.attachTag(named: "Roadmap", to: meeting)

        #expect(meeting.tags.map(\.id) == [existing.id])
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).count == 1)
    }

    @Test func attachTagCreatesAMissingTag() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")

        try library.attachTag(named: "Q3", to: meeting)

        #expect(meeting.tags.map(\.name) == ["Q3"])
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).count == 1)
    }

    @Test func applyTagsAttachesByIDAndByNameWithoutDuplicates() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        let roadmap = try #require(try library.createTag(named: "Roadmap"))
        let hiring = try #require(try library.createTag(named: "Hiring"))
        try library.attachTag(named: "Hiring", to: meeting)

        try library.applyTags(
            ids: [roadmap.id, hiring.id, UUID()],
            newNames: ["roadmap", "Budget", "budget", "  "],
            to: meeting
        )

        #expect(Set(meeting.tags.map(\.name)) == ["Roadmap", "Hiring", "Budget"])
        #expect(meeting.tags.count == 3)
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).count == 3)
    }

    @Test func deleteTagDetachesItFromMeetings() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Standup")
        try library.attachTag(named: "Roadmap", to: meeting)
        let tag = try #require(meeting.tags.first)

        try library.deleteTag(tag)

        #expect(meeting.tags.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
    }

    @Test func mergeTagMovesMeetingsOntoTheTargetAndDeletesTheSource() throws {
        let (library, context) = makeLibrary()
        let first = try library.createMeeting(title: "One")
        let second = try library.createMeeting(title: "Two")
        try library.attachTag(named: "Plan", to: first)
        try library.attachTag(named: "Plan", to: second)
        try library.attachTag(named: "Roadmap", to: second)
        let source = try #require(library.existingTag(named: "Plan"))
        let target = try #require(library.existingTag(named: "Roadmap"))

        try library.mergeTag(source, into: target)

        #expect(first.tags.map(\.name) == ["Roadmap"])
        #expect(second.tags.map(\.name) == ["Roadmap"])
        #expect(try context.fetch(FetchDescriptor<Kurn.Tag>()).map(\.name) == ["Roadmap"])
    }

    // MARK: - Folders

    @Test func createFolderTrimsTheNameAndKeepsTheParent() throws {
        let (library, _) = makeLibrary()
        let parent = try library.createFolder(
            name: "Clients", iconName: FolderIconCatalog.default, colorHex: FolderColorPalette.default, parent: nil
        )
        let child = try library.createFolder(
            name: "  Acme ", iconName: FolderIconCatalog.default, colorHex: FolderColorPalette.default, parent: parent
        )
        #expect(child.name == "Acme")
        #expect(child.parent?.id == parent.id)
    }

    @Test func deleteFolderDetachesItsMeetings() throws {
        let (library, context) = makeLibrary()
        let folder = try library.createFolder(
            name: "Clients", iconName: FolderIconCatalog.default, colorHex: FolderColorPalette.default, parent: nil
        )
        let meeting = try library.createMeeting(title: "Kickoff")
        meeting.folder = folder
        try context.save()

        try library.deleteFolder(folder)

        #expect(meeting.folder == nil)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Folder>()).isEmpty)
    }

    @Test func createSmartFolderPersistsItsFilter() throws {
        let (library, context) = makeLibrary()
        var filter = MeetingFilter()
        filter.hasSummary = true

        try library.createSmartFolder(name: " With summary ", filter: filter)

        let stored = try #require(try context.fetch(FetchDescriptor<SmartFolder>()).first)
        #expect(stored.name == "With summary")
        #expect(stored.filter == filter)
    }

    // MARK: - Documents

    @Test func deleteDocumentLeavesItsSourceMeetingAlone() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Review")
        let document = GeneratedDocument(
            title: "Review summary", bodyMarkdown: "Derived text", userPrompt: "Summarize",
            sourceKind: .transcripts, sourceNames: [meeting.title], sourceMeetingIDs: [meeting.id],
            generatorModelIdentifier: "test"
        )
        context.insert(document)
        try context.save()

        try library.deleteDocument(document)

        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
    }
}
