//
//  MeetingsViewModelTests.swift
//  MeetSyncTests
//

import Foundation
import SwiftData
import Testing
@testable import MeetSync

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
}
