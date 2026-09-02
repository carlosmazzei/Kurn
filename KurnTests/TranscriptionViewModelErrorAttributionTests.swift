//
//  TranscriptionViewModelErrorAttributionTests.swift
//  KurnTests
//
//  H9 PR 21: `TranscriptionViewModel` is one app-wide shared instance
//  (`KurnApp`, injected via `.environment`, read by every `MeetingDetailView`
//  through `@Environment`) — before this PR, a transcription failure for any
//  recording set the same single `error: AppError?` property, so two
//  recordings failing around the same time could clobber or misattribute
//  each other's error. `errorsByRecording` fixes that by keying the failure
//  to the recording it actually belongs to; these tests pin the isolation
//  directly rather than through the full `transcribe()` pipeline, which
//  needs real engines this test target doesn't link.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionViewModelErrorAttributionTests {

    private func makeRecording(meeting: Meeting, context: ModelContext) -> Recording {
        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 10)
        context.insert(recording)
        return recording
    }

    @Test func concurrentFailuresForDifferentRecordingsDoNotClobberEachOther() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Two recordings")
        context.insert(meeting)
        let recordingA = makeRecording(meeting: meeting, context: context)
        let recordingB = makeRecording(meeting: meeting, context: context)
        try context.save()

        let viewModel = TranscriptionViewModel(modelContext: context)
        viewModel.setTranscriptionErrorForTesting(.transcriptionFailed("engine A crashed"), for: recordingA)
        viewModel.setTranscriptionErrorForTesting(.audioError("engine B: unreadable file"), for: recordingB)

        let errorA = try #require(viewModel.transcriptionError(for: recordingA))
        let errorB = try #require(viewModel.transcriptionError(for: recordingB))
        #expect(errorA.logCode == "transcription")
        #expect(errorB.logCode == "audio")
    }

    @Test func clearingOneRecordingsErrorLeavesTheOtherIntact() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Two recordings")
        context.insert(meeting)
        let recordingA = makeRecording(meeting: meeting, context: context)
        let recordingB = makeRecording(meeting: meeting, context: context)
        try context.save()

        let viewModel = TranscriptionViewModel(modelContext: context)
        viewModel.setTranscriptionErrorForTesting(.transcriptionFailed("A"), for: recordingA)
        viewModel.setTranscriptionErrorForTesting(.transcriptionFailed("B"), for: recordingB)

        viewModel.clearTranscriptionError(for: recordingA)

        #expect(viewModel.transcriptionError(for: recordingA) == nil)
        #expect(viewModel.transcriptionError(for: recordingB) != nil)
    }

    @Test func recordingWithNoFailureReportsNoError() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Clean")
        context.insert(meeting)
        let recording = makeRecording(meeting: meeting, context: context)
        try context.save()

        let viewModel = TranscriptionViewModel(modelContext: context)

        #expect(viewModel.transcriptionError(for: recording) == nil)
    }
}
