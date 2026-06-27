//
//  MeetingsViewModelTests.swift
//  KurnTests
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingsViewModelTests {

    private func makeViewModel() -> (MeetingsViewModel, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        return (MeetingsViewModel(modelContext: context), context)
    }

    @Test func createMeetingUsesTrimmedTitle() {
        let (viewModel, _) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "  Sprint Planning  ")
        #expect(meeting.title == "Sprint Planning")
    }

    @Test func createMeetingFallsBackToDefaultTitleWhenBlank() {
        let (viewModel, _) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "   ")
        #expect(!meeting.title.isEmpty)
        #expect(meeting.title != "   ")
    }

    @Test func createMeetingPersistsLanguageAndNotes() {
        let (viewModel, _) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "Standup", notes: "Daily sync", language: .portuguese)
        #expect(meeting.notes == "Daily sync")
        #expect(meeting.language == .portuguese)
    }

    @Test func createMeetingInsertsIntoContext() throws {
        let (viewModel, context) = makeViewModel()
        viewModel.createMeeting(title: "Standup")
        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.count == 1)
    }

    @Test func deleteRemovesMeetingFromContext() throws {
        let (viewModel, context) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "Standup")
        viewModel.delete(meeting)
        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.isEmpty)
    }

    // MARK: - Audio file cleanup

    /// Write a placeholder audio file in Documents and return its name + URL.
    private func makeAudioFile() throws -> (name: String, url: URL) {
        let name = "test_\(UUID().uuidString).m4a"
        let url = AudioFileStore.documentsURL.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return (name, url)
    }

    @Test func deleteRecordingRemovesAudioFileAndModel() throws {
        let (viewModel, context) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "Standup")
        let file = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: file.url) }
        #expect(FileManager.default.fileExists(atPath: file.url.path))

        let recording = Recording(meeting: meeting, fileName: file.name, duration: 12)
        context.insert(recording)
        try context.save()

        viewModel.deleteRecording(recording)

        // The audio file is gone from disk…
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        // …and the model is removed from the store.
        let remaining = try context.fetch(FetchDescriptor<Recording>())
        #expect(remaining.isEmpty)
    }

    @Test func deleteMeetingRemovesItsRecordingAudioFiles() throws {
        let (viewModel, context) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "Standup")
        let file = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let recording = Recording(meeting: meeting, fileName: file.name, duration: 8)
        context.insert(recording)
        try context.save()

        viewModel.delete(meeting)

        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func deleteMeetingRemovesEveryRecordingAudioFile() throws {
        let (viewModel, context) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "Standup")
        let first = try makeAudioFile()
        let second = try makeAudioFile()
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }

        context.insert(Recording(meeting: meeting, fileName: first.name, duration: 5))
        context.insert(Recording(meeting: meeting, fileName: second.name, duration: 6))
        try context.save()

        viewModel.delete(meeting)

        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        let remaining = try context.fetch(FetchDescriptor<Recording>())
        #expect(remaining.isEmpty)
    }

    @Test func createMeetingTreatsNewlineAndTabOnlyTitleAsBlank() {
        let (viewModel, _) = makeViewModel()
        let meeting = viewModel.createMeeting(title: "\n\t  ")
        #expect(!meeting.title.isEmpty)
        #expect(!meeting.title.contains("\n"))
    }
}
