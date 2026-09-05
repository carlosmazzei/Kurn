//
//  RecorderViewModelStateMachineTests.swift
//  KurnTests
//
//  `RecorderViewModel` driven through a real `AudioRecorderService` whose
//  capture engine, sink and microphone permission are scripted fakes
//  (`FakeAudioCaptureEngine`, `FakeAudioSinkWriting`), with the two
//  persistence seams (`RecordingFileFinalizing`, `RecordingLifecycleSaving`)
//  doubled as well. Covers the paths only a device used to exercise: start
//  (permission denied, engine failure, already active), pause/resume for every
//  `PauseReason`, stop with a ready / partial / too-short / unreadable file,
//  stop when nothing is active, cancel, error dismissal that completes the
//  sheet, and the abandoned-view teardown.
//

import AVFoundation
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("RecorderViewModel state machine")
struct RecorderViewModelStateMachineTests {

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let meeting: Meeting
        let engine: FakeAudioCaptureEngine
        let sink: FakeAudioSinkWriting
        let recorder: AudioRecorderService
        let saver: ScriptedRecordingLifecycleSaver
        let viewModel: RecorderViewModel
        private let savedCount: Counter

        init(
            permissionGranted: Bool = true,
            finalizer: any RecordingFileFinalizing = StubRecordingFileFinalizer(
                result: FinalizedRecordingFile(duration: 4, fileSize: 2_048)
            ),
            failSaveOnCall: Int? = nil
        ) throws {
            container = TestModelContainer.make()
            context = container.mainContext
            meeting = Meeting(title: "Recorder")
            context.insert(meeting)
            try context.save()
            engine = FakeAudioCaptureEngine()
            sink = FakeAudioSinkWriting()
            recorder = AudioRecorderService(
                engine: engine,
                sink: sink,
                stallInterval: 3_600,
                microphonePermission: { permissionGranted }
            )
            saver = ScriptedRecordingLifecycleSaver(failOnCall: failSaveOnCall)
            let counter = Counter()
            savedCount = counter
            viewModel = RecorderViewModel(
                meeting: meeting,
                modelContext: context,
                defaultMode: .onDevice,
                options: RecorderOptions(alwaysUseBuiltInMic: true),
                recorder: recorder,
                fileFinalizer: finalizer,
                lifecycleSaver: saver,
                onRecordingSaved: { counter.increment() }
            )
        }

        var recordingsSaved: Int { savedCount.value }

        func recordings() throws -> [Recording] {
            try context.fetch(FetchDescriptor<Recording>())
        }

        func cleanUp() {
            viewModel.cancel()
        }
    }

    @MainActor
    private final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    // MARK: - Start

    @Test func startRecordsAndPersistsTheRecordingAsCapturing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        await harness.viewModel.startRecording()

        #expect(harness.viewModel.state == .recording)
        #expect(!harness.viewModel.isStarting)
        #expect(harness.viewModel.error == nil)
        #expect(!harness.viewModel.permissionDenied)
        let recording = try #require(try harness.recordings().first)
        #expect(recording.captureState == .recording)
        #expect(recording.meeting?.id == harness.meeting.id)
        #expect(recording.transcriptionMode == .onDevice)
        #expect(harness.engine.isRunning)
    }

    @Test func deniedMicrophonePermissionNeverTouchesTheEngineOrTheStore() async throws {
        let harness = try Harness(permissionGranted: false)

        await harness.viewModel.startRecording()

        #expect(harness.viewModel.permissionDenied)
        #expect(harness.viewModel.state == .idle)
        #expect(harness.engine.calls.isEmpty)
        #expect(try harness.recordings().isEmpty)
    }

    @Test func engineStartFailureRemovesTheEmptyRecordingAndSurfacesTheError() async throws {
        let harness = try Harness()
        harness.engine.failSessionConfiguration()

        await harness.viewModel.startRecording()

        #expect(harness.viewModel.state == .idle)
        #expect(harness.viewModel.error != nil)
        #expect(!harness.viewModel.didSaveRecording)
        #expect(try harness.recordings().isEmpty)
        #expect(!harness.engine.isRunning)
    }

    @Test func provisionalSaveFailureStopsBeforeTheEngineStarts() async throws {
        let harness = try Harness(failSaveOnCall: 1)

        await harness.viewModel.startRecording()

        guard case .persistenceFailed = harness.viewModel.error else {
            Issue.record("expected a persistence error")
            return
        }
        #expect(harness.viewModel.state == .idle)
        #expect(harness.engine.count(.start) == 0)
        #expect(try harness.recordings().isEmpty)
    }

    @Test func secondStartWhileActiveIsRejectedWithoutDisturbingTheFirst() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.viewModel.startRecording()

        await harness.viewModel.startRecording()

        guard case .audioError = harness.viewModel.error else {
            Issue.record("expected the already-active error")
            return
        }
        #expect(harness.viewModel.state == .recording)
        #expect(try harness.recordings().count == 1)
        #expect(harness.engine.count(.start) == 1)
    }

    // MARK: - Pause / resume

    @Test func togglePauseAlternatesBetweenRecordingAndPaused() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.viewModel.startRecording()

        harness.viewModel.togglePause()
        #expect(harness.viewModel.state == .paused)
        #expect(harness.sink.isPaused)

        harness.viewModel.togglePause()
        #expect(harness.viewModel.state == .recording)
        #expect(!harness.sink.isPaused)
    }

    @Test func togglePauseWhileIdleIsANoOp() throws {
        let harness = try Harness()

        harness.viewModel.togglePause()

        #expect(harness.viewModel.state == .idle)
        #expect(harness.engine.calls.isEmpty)
    }

    @Test(arguments: [
        AudioRecorderPauseReason.userToggle,
        .watchCommand,
        .audioInterruption,
        .engineRecoveryFailed,
        .engineRestartFailed,
        .routeChanged,
        .sinkFailure,
        .captureStalled
    ])
    func everyPauseReasonPausesAndResumeContinuesTheSameRecording(reason: AudioRecorderPauseReason) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.viewModel.startRecording()

        harness.recorder.pause(reason: reason)
        #expect(harness.viewModel.state == .paused)
        #expect(try harness.recordings().count == 1)

        harness.viewModel.togglePause()
        #expect(harness.viewModel.state == .recording)
        #expect(harness.engine.isRunning)
    }

    @Test func highlightsAreCountedOnlyWhileRecording() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.viewModel.markHighlight()
        #expect(harness.viewModel.highlightCount == 0)

        await harness.viewModel.startRecording()
        harness.viewModel.markHighlight()
        harness.viewModel.togglePause()
        harness.viewModel.markHighlight()

        #expect(harness.viewModel.highlightCount == 1)
    }

    // MARK: - Stop

    @Test func stopAndSaveFinalizesAReadyRecordingAndReportsIt() async throws {
        let harness = try Harness()
        await harness.viewModel.startRecording()
        harness.viewModel.markHighlight()

        let finalized = harness.viewModel.stopAndSave()

        #expect(finalized)
        #expect(harness.viewModel.state == .idle)
        #expect(harness.viewModel.didSaveRecording)
        #expect(harness.viewModel.error == nil)
        #expect(harness.recordingsSaved == 1)
        let recording = try #require(try harness.recordings().first)
        #expect(recording.captureState == .ready)
        #expect(recording.captureRecoveryReason == nil)
        #expect(recording.duration == 4)
        #expect(recording.fileSize == 2_048)
        #expect(recording.highlights.count == 1)
        #expect(!harness.engine.isRunning)
    }

    @Test func stopAndSaveWithNothingActiveIsALegitimateNoOp() throws {
        let harness = try Harness()

        #expect(harness.viewModel.stopAndSave())
        #expect(!harness.viewModel.didSaveRecording)
        #expect(harness.viewModel.error == nil)
        #expect(try harness.recordings().isEmpty)
    }

    @Test func sinkFailureDuringCaptureKeepsThePartialRecordingForRecovery() async throws {
        let harness = try Harness()
        harness.sink.failOnClose()
        await harness.viewModel.startRecording()

        let finalized = harness.viewModel.stopAndSave()

        #expect(!finalized)
        #expect(!harness.viewModel.didSaveRecording)
        guard case .audioError = harness.viewModel.error else {
            Issue.record("expected the partial-saved notice")
            return
        }
        let recording = try #require(try harness.recordings().first)
        #expect(recording.captureState == .recoveryNeeded)
        #expect(recording.captureRecoveryReason == .finalDrainFailed)
        #expect(recording.duration == 4)
        #expect(harness.recordingsSaved == 1)

        harness.viewModel.dismissError()
        #expect(harness.viewModel.error == nil)
        #expect(harness.viewModel.didSaveRecording)
    }

    @Test func unreadableFileIsKeptAsRecoveryNeededNotDeleted() async throws {
        let harness = try Harness(
            finalizer: StubRecordingFileFinalizer(failure: RecordingFileFinalizationError.unreadable)
        )
        await harness.viewModel.startRecording()

        let finalized = harness.viewModel.stopAndSave()

        #expect(!finalized)
        let recording = try #require(try harness.recordings().first)
        #expect(recording.captureState == .recoveryNeeded)
        #expect(recording.captureRecoveryReason == .unreadableFile)
        #expect(harness.recordingsSaved == 0)
    }

    @Test func tooShortRecordingIsDiscardedButStillCompletesTheSheet() async throws {
        let harness = try Harness(
            finalizer: StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 0.2, fileSize: 64))
        )
        await harness.viewModel.startRecording()

        let finalized = harness.viewModel.stopAndSave()

        #expect(finalized)
        #expect(harness.viewModel.didSaveRecording)
        #expect(harness.viewModel.error == nil)
        #expect(try harness.recordings().isEmpty)
        #expect(harness.recordingsSaved == 0)
    }

    @Test func finalSaveFailureSurfacesAPersistenceErrorAndDoesNotComplete() async throws {
        let harness = try Harness(failSaveOnCall: 4)
        await harness.viewModel.startRecording()

        let finalized = harness.viewModel.stopAndSave()

        #expect(!finalized)
        #expect(!harness.viewModel.didSaveRecording)
        guard case .persistenceFailed = harness.viewModel.error else {
            Issue.record("expected a persistence error")
            return
        }
        #expect(harness.recordingsSaved == 0)
        #expect(harness.viewModel.state == .idle)

        harness.viewModel.dismissError()
        #expect(!harness.viewModel.didSaveRecording)
    }

    @Test func stopWhilePausedStillFinalizes() async throws {
        let harness = try Harness()
        await harness.viewModel.startRecording()
        harness.viewModel.togglePause()

        #expect(harness.viewModel.stopAndSave())
        #expect(harness.viewModel.didSaveRecording)
        #expect(try harness.recordings().first?.captureState == .ready)
    }

    // MARK: - Cancel / teardown

    @Test func cancelDeletesTheRecordingAndStopsTheEngine() async throws {
        let harness = try Harness()
        await harness.viewModel.startRecording()

        harness.viewModel.cancel()

        #expect(harness.viewModel.state == .idle)
        #expect(!harness.viewModel.didSaveRecording)
        #expect(harness.viewModel.error == nil)
        #expect(try harness.recordings().isEmpty)
        #expect(!harness.engine.isRunning)
        #expect(harness.recordingsSaved == 0)
    }

    @Test func cancelWithNothingActiveIsANoOp() throws {
        let harness = try Harness()

        harness.viewModel.cancel()

        #expect(harness.viewModel.state == .idle)
        #expect(harness.viewModel.error == nil)
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func finalizeIfAbandonedSavesAnInFlightRecording() async throws {
        let harness = try Harness()
        await harness.viewModel.startRecording()

        harness.viewModel.finalizeIfAbandoned()

        #expect(harness.viewModel.didSaveRecording)
        #expect(harness.viewModel.state == .idle)
        #expect(try harness.recordings().first?.captureState == .ready)
    }

    @Test func finalizeIfAbandonedAfterANormalStopIsANoOp() async throws {
        let harness = try Harness()
        await harness.viewModel.startRecording()
        harness.viewModel.stopAndSave()
        let saves = harness.recordingsSaved

        harness.viewModel.finalizeIfAbandoned()

        #expect(harness.recordingsSaved == saves)
        #expect(try harness.recordings().count == 1)
    }

    @Test func meetingTitleEditsWriteThroughToTheMeeting() throws {
        let harness = try Harness()

        harness.viewModel.meetingTitle = "Renamed"

        #expect(harness.meeting.title == "Renamed")
        #expect(harness.viewModel.meetingTitle == "Renamed")
    }
}
