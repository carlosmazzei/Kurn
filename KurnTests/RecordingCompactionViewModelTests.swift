//
//  RecordingCompactionViewModelTests.swift
//  KurnTests
//
//  `RecordingCompactionViewModel` over an in-memory store. Only the
//  bookkeeping is exercised here — which recordings count as candidates, the
//  largest-meetings breakdown, and how a run settles — with candidate files
//  that are absent on disk, so the compactor leaves them alone without ever
//  decoding AAC (which the simulator does unreliably). The re-encode itself is
//  `RecordingCompactorTests`' job.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingCompactionViewModelTests {

    private static let target = AudioQuality.standard.bitRate
    /// A minute at four times the target rate: comfortably worth compacting.
    private static let fatSize = Int64(60 * Double(target) / 8 * 4)

    @discardableResult
    private static func recording(
        _ meeting: Meeting,
        in context: ModelContext,
        fileSize: Int64 = fatSize,
        status: TranscriptionStatus = .done,
        captureState: RecordingCaptureState = .ready
    ) -> Recording {
        let recording = Recording(
            meeting: meeting,
            fileName: "absent-\(UUID().uuidString).m4a",
            duration: 60,
            transcriptionStatus: status,
            captureState: captureState,
            fileSize: fileSize
        )
        context.insert(recording)
        return recording
    }

    private static func meeting(_ title: String, in context: ModelContext) -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        return meeting
    }

    private static func waitUntilIdle(_ viewModel: RecordingCompactionViewModel) async {
        let deadline = Date().addingTimeInterval(180)
        while viewModel.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func refreshCountsOnlyFinishedReadyAndOversizedRecordings() throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Self.meeting("Planning", in: context)
        Self.recording(meeting, in: context)
        Self.recording(meeting, in: context, status: .pending)
        Self.recording(meeting, in: context, captureState: .recoveryNeeded)
        Self.recording(meeting, in: context, fileSize: Int64(60 * Double(Self.target) / 8))
        try context.save()
        let viewModel = RecordingCompactionViewModel(modelContext: context)

        viewModel.refresh(targetBitRate: Self.target)

        #expect(viewModel.candidateCount == 1)
        #expect(viewModel.estimatedSavings > 0)
        #expect(!viewModel.isRunning)
    }

    @Test func largestMeetingsSumsPerMeetingAndSkipsUnmeasuredFiles() {
        let context = ModelContext(TestModelContainer.make())
        let big = Self.meeting("Big", in: context)
        let small = Self.meeting("Small", in: context)
        let unmeasured = Self.meeting("Unmeasured", in: context)
        let recordings = [
            Self.recording(big, in: context, fileSize: 300),
            Self.recording(big, in: context, fileSize: 200),
            Self.recording(small, in: context, fileSize: 400),
            Self.recording(unmeasured, in: context, fileSize: 0)
        ]

        let usage = RecordingCompactionViewModel.largestMeetings(from: recordings, limit: 8)
        #expect(usage.map(\.title) == ["Big", "Small"])
        #expect(usage.first?.bytes == 500)
        #expect(usage.first?.duration == 120)

        let capped = RecordingCompactionViewModel.largestMeetings(from: recordings, limit: 1)
        #expect(capped.map(\.title) == ["Big"])
    }

    @Test func aRunWithNoCandidatesFinishesWithZeroSavings() async {
        let context = ModelContext(TestModelContainer.make())
        let viewModel = RecordingCompactionViewModel(modelContext: context)

        viewModel.start(targetBitRate: Self.target)
        #expect(viewModel.isRunning)
        await Self.waitUntilIdle(viewModel)

        #expect(viewModel.completedSavings == 0)
        #expect(viewModel.error == nil)
    }

    @Test func aRunOverAbsentFilesReclaimsNothingAndRemeasuresThem() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Self.meeting("Planning", in: context)
        let first = Self.recording(meeting, in: context)
        let second = Self.recording(meeting, in: context)
        try context.save()
        let viewModel = RecordingCompactionViewModel(modelContext: context)

        viewModel.start(targetBitRate: Self.target)
        viewModel.start(targetBitRate: Self.target)
        await Self.waitUntilIdle(viewModel)

        #expect(viewModel.completedSavings == 0)
        #expect(viewModel.error == nil)
        #expect(first.fileSize == 0)
        #expect(second.fileSize == 0)
        #expect(viewModel.candidateCount == 0)
        #expect(viewModel.progress == nil)
    }

    @Test func cancellingStopsTheRun() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Self.meeting("Planning", in: context)
        Self.recording(meeting, in: context)
        try context.save()
        let viewModel = RecordingCompactionViewModel(modelContext: context)

        viewModel.cancel()
        viewModel.start(targetBitRate: Self.target)
        viewModel.cancel()
        await Self.waitUntilIdle(viewModel)

        #expect(!viewModel.isRunning)
        #expect(viewModel.error == nil)
    }
}
