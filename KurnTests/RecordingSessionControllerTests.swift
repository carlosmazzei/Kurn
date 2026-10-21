//
//  RecordingSessionControllerTests.swift
//  KurnTests
//
//  `RecordingSessionController` owns the live recording session so the
//  recorder can be minimized into the mini bar. Each test builds the session's
//  `RecorderViewModel` over the same scripted fakes as
//  `RecorderViewModelStateMachineTests` (no microphone, no audio session) and
//  replaces the production start with a recorder of calls, driving
//  `startRecording()` itself so every transition is deterministic.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("RecordingSessionController")
struct RecordingSessionControllerTests {

    /// The view models the controller asked to start, in order.
    @MainActor
    private final class PrepareLog {
        var calls: [RecorderViewModel] = []
    }

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let meeting: Meeting
        let log: PrepareLog
        let controller: RecordingSessionController

        var prepared: [RecorderViewModel] { log.calls }

        init(permissionGranted: Bool = true) throws {
            let container = TestModelContainer.make()
            let context = container.mainContext
            let meeting = Meeting(title: "Session")
            context.insert(meeting)
            try context.save()
            let log = PrepareLog()
            self.container = container
            self.context = context
            self.meeting = meeting
            self.log = log
            controller = RecordingSessionController(
                modelContext: context,
                settings: AppSettings(),
                makeViewModel: { meeting, context in
                    RecorderViewModel(
                        meeting: meeting,
                        modelContext: context,
                        defaultMode: .onDevice,
                        options: RecorderOptions(alwaysUseBuiltInMic: true),
                        recorder: AudioRecorderService(
                            engine: FakeAudioCaptureEngine(),
                            sink: FakeAudioSinkWriting(),
                            stallInterval: 3_600,
                            microphonePermission: { permissionGranted }
                        ),
                        fileFinalizer: StubRecordingFileFinalizer(
                            result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)
                        ),
                        lifecycleSaver: ScriptedRecordingLifecycleSaver()
                    )
                },
                prepare: { viewModel in log.calls.append(viewModel) }
            )
        }

        /// Begins a session into `meeting` and starts capture.
        func beginRecording() async throws -> RecorderViewModel {
            controller.begin(meeting: meeting)
            let viewModel = try #require(controller.viewModel)
            await viewModel.startRecording()
            return viewModel
        }

        func recordings() throws -> [Recording] {
            try context.fetch(FetchDescriptor<Recording>())
        }

        func cleanUp() {
            controller.discard()
        }
    }

    // MARK: - Begin

    @Test func beginStartsAnExpandedSessionAndRunsTheStart() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let started = harness.controller.begin(meeting: harness.meeting)

        #expect(started)
        #expect(harness.controller.isActive)
        #expect(harness.controller.isExpanded)
        #expect(harness.controller.isRecording(into: harness.meeting))
        var attempts = 0
        while harness.prepared.isEmpty, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(harness.prepared.count == 1)
        #expect(harness.prepared.first === harness.controller.viewModel)
    }

    @Test func beginWhileASessionIsActiveReopensItInsteadOfStartingAnother() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let viewModel = try await harness.beginRecording()
        harness.controller.minimize()
        let other = Meeting(title: "Other")
        harness.context.insert(other)

        let started = harness.controller.begin(meeting: other)

        #expect(!started)
        #expect(harness.controller.isExpanded)
        #expect(harness.controller.viewModel === viewModel)
        #expect(harness.controller.isRecording(into: harness.meeting))
        #expect(!harness.controller.isRecording(into: other))
    }

    // MARK: - Minimize / expand

    @Test func cannotMinimizeBeforeCaptureIsRunning() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.controller.begin(meeting: harness.meeting)

        #expect(!harness.controller.canMinimize)
        harness.controller.minimize()
        harness.controller.setPresented(false)

        #expect(harness.controller.isExpanded)
    }

    @Test func minimizeAndExpandKeepTheCaptureRunning() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let viewModel = try await harness.beginRecording()
        #expect(harness.controller.canMinimize)

        harness.controller.minimize()
        #expect(!harness.controller.isExpanded)
        #expect(harness.controller.isActive)
        #expect(viewModel.state == .recording)

        harness.controller.expand()
        #expect(harness.controller.isExpanded)
        #expect(viewModel.state == .recording)
    }

    @Test func swipingTheRecorderAwayMinimizesInsteadOfDiscarding() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let viewModel = try await harness.beginRecording()

        harness.controller.setPresented(false)

        #expect(!harness.controller.isExpanded)
        #expect(viewModel.state == .recording)
        #expect(try harness.recordings().count == 1)

        harness.controller.setPresented(true)
        #expect(harness.controller.isExpanded)
    }

    @Test func expandWithoutASessionIsANoOp() throws {
        let harness = try Harness()

        harness.controller.expand()
        harness.controller.surfaceIfNeeded()

        #expect(!harness.controller.isExpanded)
        #expect(!harness.controller.canMinimize)
    }

    @Test func isPausedFollowsTheLiveSession() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        #expect(!harness.controller.isPaused)
        let viewModel = try await harness.beginRecording()
        #expect(!harness.controller.isPaused)

        viewModel.togglePause()
        #expect(harness.controller.isPaused)

        viewModel.togglePause()
        #expect(!harness.controller.isPaused)
    }

    // MARK: - Attention

    @Test func anErrorBringsAMinimizedRecorderBack() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let viewModel = try await harness.beginRecording()
        harness.controller.minimize()

        harness.controller.surfaceIfNeeded()
        #expect(!harness.controller.isExpanded)

        viewModel.error = .audioError("capture failed")
        harness.controller.surfaceIfNeeded()
        #expect(harness.controller.isExpanded)
    }

    @Test func aPermissionDenialKeepsTheRecorderPresented() async throws {
        let harness = try Harness(permissionGranted: false)
        harness.controller.begin(meeting: harness.meeting)
        let viewModel = try #require(harness.controller.viewModel)

        await viewModel.startRecording()
        harness.controller.surfaceIfNeeded()

        #expect(viewModel.permissionDenied)
        #expect(harness.controller.isExpanded)
        #expect(!harness.controller.canMinimize)

        harness.controller.discard()
        #expect(!harness.controller.isActive)
        #expect(try harness.recordings().isEmpty)
    }

    // MARK: - End

    @Test func stoppingFromTheMiniBarEndsTheSessionOnceSaved() async throws {
        let harness = try Harness()
        let viewModel = try await harness.beginRecording()
        harness.controller.minimize()

        harness.controller.finishIfSaved()
        #expect(harness.controller.isActive)

        viewModel.stopAndSave()
        harness.controller.finishIfSaved()

        #expect(!harness.controller.isActive)
        #expect(!harness.controller.isExpanded)
        #expect(harness.controller.meeting == nil)
        #expect(try harness.recordings().first?.captureState == .ready)
    }

    @Test func discardDeletesTheInProgressRecordingAndEndsTheSession() async throws {
        let harness = try Harness()
        _ = try await harness.beginRecording()
        #expect(try harness.recordings().count == 1)

        harness.controller.discard()

        #expect(!harness.controller.isActive)
        #expect(!harness.controller.isExpanded)
        #expect(try harness.recordings().isEmpty)
    }

    @Test func theProductionFactoryBuildsTheSessionFromSettings() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Defaults")
        context.insert(meeting)
        try context.save()
        let controller = RecordingSessionController(
            modelContext: context,
            settings: AppSettings(),
            prepare: { _ in }
        )

        controller.begin(meeting: meeting)

        let viewModel = try #require(controller.viewModel)
        #expect(viewModel.state == .idle)
        #expect(viewModel.meetingTitle == "Defaults")
        controller.discard()
        #expect(!controller.isActive)
    }
}
