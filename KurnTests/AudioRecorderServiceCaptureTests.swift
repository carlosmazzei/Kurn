//
//  AudioRecorderServiceCaptureTests.swift
//  KurnTests
//
//  Drives `AudioRecorderService`'s state machine through a scripted
//  `AudioCaptureEngine` and sink: start/pause/resume/stop/cancel, the system
//  events (interruption, route loss, configuration change, media-services
//  reset) and the recovery paths that until now only a device could exercise.
//

import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
@Suite("AudioRecorderService with a scripted capture engine")
struct AudioRecorderServiceCaptureTests {
    @MainActor
    private struct Harness {
        let engine: FakeAudioCaptureEngine
        let sink: FakeAudioSinkWriting
        let recorder: AudioRecorderService
        let fileName: String

        init(engine: FakeAudioCaptureEngine = FakeAudioCaptureEngine()) {
            self.engine = engine
            sink = FakeAudioSinkWriting()
            recorder = AudioRecorderService(engine: engine, sink: sink, stallInterval: 2)
            fileName = "capture-test-\(UUID().uuidString).m4a"
        }

        func start() async throws {
            try await recorder.start(fileName: fileName)
        }

        func cleanUp() {
            recorder.cancel()
            AudioFileStore.delete(fileName: fileName)
        }
    }

    // MARK: - Start

    @Test func startConfiguresTheSessionOpensTheFileInstallsTheTapAndRuns() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let transitions = TransitionRecorder()
        harness.recorder.onStateChanged = { state, _ in transitions.append(state) }

        try await harness.start()

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.isTapInstalled)
        #expect(harness.sink.openCount == 1)
        #expect(harness.engine.calls == [
            .configureSession, .disableVoiceProcessing, .openOutputFile, .installTap, .prepare, .start
        ])
        #expect(transitions.values == [.recording])
        #expect(harness.recorder.captureFailure == nil)
        #expect(harness.recorder.storageState != .unknown)
    }

    @Test func startWaitsForABluetoothRouteToNegotiateItsFormat() async throws {
        let engine = FakeAudioCaptureEngine(inputFormats: [nil, FakeAudioCaptureEngine.bluetoothHFP])
        let harness = Harness(engine: engine)
        defer { harness.cleanUp() }

        try await harness.start()

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isTapInstalled)
    }

    @Test func startRejectsASecondStartWhileRecording() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        await #expect(throws: AppError.self) {
            try await harness.recorder.start(fileName: "second-\(harness.fileName)")
        }
        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.count(.configureSession) == 1)
    }

    @Test func sessionConfigurationFailureCleansUpAndLeavesTheRecorderIdle() async throws {
        let engine = FakeAudioCaptureEngine()
        engine.failSessionConfiguration(with: AppError.audioError("session"))
        let harness = Harness(engine: engine)
        defer { harness.cleanUp() }

        await #expect(throws: AppError.self) { try await harness.start() }

        #expect(harness.recorder.state == .idle)
        #expect(!harness.engine.isTapInstalled)
        #expect(harness.engine.count(.deactivateSession) == 1)
        #expect(harness.sink.closeCount == 1)
        #expect(harness.recorder.stop() == nil)
    }

    @Test func engineStartFailureIsReportedAsAnAudioErrorAndTheTapIsRemoved() async throws {
        let engine = FakeAudioCaptureEngine()
        engine.failNextStarts(1)
        let harness = Harness(engine: engine)
        defer { harness.cleanUp() }

        await #expect(throws: AppError.self) { try await harness.start() }

        #expect(harness.recorder.state == .idle)
        #expect(harness.engine.count(.installTap) == 1)
        #expect(harness.engine.count(.removeTap) == 1)
        #expect(!harness.engine.isRunning)
    }

    @Test func cancelDuringStartAbortsTheStartWithoutRecording() async throws {
        let engine = FakeAudioCaptureEngine()
        engine.holdSessionConfiguration()
        let harness = Harness(engine: engine)
        defer { harness.cleanUp() }
        let recorder = harness.recorder
        let fileName = harness.fileName

        let starting = Task { @MainActor in try await recorder.start(fileName: fileName) }
        for _ in 0..<1_000 where engine.count(.configureSession) == 0 {
            await Task.yield()
        }
        #expect(engine.count(.configureSession) == 1)

        recorder.cancel()
        engine.releaseSessionConfiguration()

        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(recorder.state == .idle)
        #expect(!engine.isRunning)
        #expect(!engine.isTapInstalled)
        #expect(engine.count(.deactivateSession) == 1)
    }

    // MARK: - Pause / resume / highlight / stop

    @Test func pauseAndResumeToggleTheSinkAndRestartAStoppedEngine() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        let transitions = TransitionRecorder()
        harness.recorder.onStateChanged = { state, _ in transitions.append(state) }

        harness.recorder.pause(reason: .userToggle)
        #expect(harness.recorder.state == .paused)
        #expect(harness.sink.isPaused)
        #expect(harness.recorder.level == 0)

        harness.engine.stopBehindTheRecordersBack()
        harness.recorder.resume()

        #expect(harness.recorder.state == .recording)
        #expect(!harness.sink.isPaused)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.count(.start) == 2)
        #expect(transitions.values == [.paused, .recording])
    }

    @Test func pauseAndResumeAreNoOpsOutsideTheirSourceState() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }

        harness.recorder.pause(reason: .userToggle)
        harness.recorder.resume()
        #expect(harness.recorder.state == .idle)

        try await harness.start()
        harness.recorder.resume()
        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.count(.start) == 1)
    }

    @Test func resumeWithAnEngineThatWillNotStartStaysPaused() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.recorder.pause(reason: .userToggle)
        harness.engine.stopBehindTheRecordersBack()
        harness.engine.failNextStarts(1)

        harness.recorder.resume()

        #expect(harness.recorder.state == .paused)
        #expect(harness.sink.isPaused)
    }

    @Test func highlightsAreOnlyMarkedWhileRecordingAndReturnedByStop() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let added = HighlightRecorder()
        harness.recorder.onHighlightAdded = { added.append($0) }

        harness.recorder.markHighlight()
        try await harness.start()
        harness.recorder.markHighlight()
        harness.recorder.pause(reason: .userToggle)
        harness.recorder.markHighlight()
        harness.recorder.resume()
        harness.recorder.markHighlight()

        let result = try #require(harness.recorder.stop())
        #expect(result.fileName == harness.fileName)
        #expect(result.highlights.count == 2)
        #expect(added.values.count == 2)
        #expect(result.captureFailure == nil)
        #expect(result.duration >= 0)
        #expect(harness.recorder.state == .idle)
        #expect(harness.recorder.highlights.isEmpty)
        #expect(!harness.engine.isRunning)
        #expect(!harness.engine.isTapInstalled)
        #expect(harness.sink.closeCount == 1)
        #expect(harness.engine.calls.last == .deactivateSession)
    }

    @Test func stopReportsAFinalDrainFailureAsAPartialCapture() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.sink.failOnClose()

        let result = try #require(harness.recorder.stop())

        #expect(result.captureFailure == .finalDrain)
        #expect(harness.recorder.state == .idle)
    }

    @Test func cancelTearsDownAndDeletesWithoutAResult() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        let transitions = TransitionRecorder()
        harness.recorder.onStateChanged = { state, _ in transitions.append(state) }

        harness.recorder.cancel()

        #expect(harness.recorder.state == .idle)
        #expect(!harness.engine.isRunning)
        #expect(harness.sink.closeCount == 1)
        #expect(harness.engine.calls.last == .deactivateSession)
        #expect(transitions.values == [.idle])
        #expect(harness.recorder.stop() == nil)
    }

    // MARK: - System events

    @Test func interruptionPausesAndAutoResumesOnlyWhenTheSystemSaysSo() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        harness.recorder.handleCaptureEvent(.interruptionBegan)
        #expect(harness.recorder.state == .paused)

        harness.engine.stopBehindTheRecordersBack()
        harness.recorder.handleCaptureEvent(.interruptionEnded(shouldResume: false))
        #expect(harness.recorder.state == .paused)
        #expect(!harness.engine.isRunning)

        // The `shouldResume` flag only counts for the interruption that paused us.
        harness.recorder.handleCaptureEvent(.interruptionEnded(shouldResume: true))
        #expect(harness.recorder.state == .paused)

        harness.recorder.resume()
        harness.recorder.handleCaptureEvent(.interruptionBegan)
        harness.engine.stopBehindTheRecordersBack()
        harness.recorder.handleCaptureEvent(.interruptionEnded(shouldResume: true))

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.count(.reactivateSession) >= 1)
    }

    @Test func interruptionWhilePausedByTheUserDoesNotResumeOnItsOwn() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.recorder.pause(reason: .userToggle)

        harness.recorder.handleCaptureEvent(.interruptionBegan)
        harness.recorder.handleCaptureEvent(.interruptionEnded(shouldResume: true))

        #expect(harness.recorder.state == .paused)
    }

    @Test func losingTheInputRoutePausesWithABanner() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        harness.recorder.handleCaptureEvent(.inputRouteLost)

        #expect(harness.recorder.state == .paused)
        #expect(harness.recorder.routeChangeMessage != nil)

        harness.recorder.resume()
        #expect(harness.recorder.state == .recording)
        #expect(harness.recorder.routeChangeMessage == nil)

        harness.recorder.pause(reason: .userToggle)
        harness.recorder.handleCaptureEvent(.inputRouteLost)
        #expect(harness.recorder.routeChangeMessage == nil)
    }

    @Test func configurationChangeWithTheSameFormatRestartsTheEngineInPlace() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.engine.stopBehindTheRecordersBack()

        harness.recorder.handleCaptureEvent(.configurationChanged)

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.count(.installTap) == 1)
        #expect(harness.engine.count(.reactivateSession) == 1)
        #expect(harness.recorder.routeChangeMessage == nil)
    }

    @Test func configurationChangeWhileTheEngineStillRunsIsIgnored() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        harness.recorder.handleCaptureEvent(.configurationChanged)
        harness.recorder.handleCaptureEvent(.mediaServicesReset)

        #expect(harness.engine.count(.start) == 1)
        #expect(harness.recorder.state == .recording)
    }

    @Test func formatChangeRebuildsTheTapAndConverterIntoTheSameFile() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.engine.stopBehindTheRecordersBack()
        harness.engine.setInputFormats([FakeAudioCaptureEngine.bluetoothHFP])

        harness.recorder.handleCaptureEvent(.mediaServicesReset)

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isRunning)
        #expect(harness.engine.count(.removeTap) == 1)
        #expect(harness.engine.count(.installTap) == 2)
        #expect(harness.sink.convertersReplaced == 1)
        #expect(harness.sink.openCount == 1)
    }

    @Test func unusableNewFormatPausesWithTheEngineStalledBanner() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.engine.stopBehindTheRecordersBack()
        harness.engine.setInputFormats([nil])

        harness.recorder.handleCaptureEvent(.configurationChanged)

        #expect(harness.recorder.state == .paused)
        #expect(harness.recorder.routeChangeMessage != nil)
        #expect(!harness.engine.isRunning)
        #expect(harness.engine.count(.installTap) == 1)
    }

    @Test func failedRestartAfterConfigurationChangePausesWithABanner() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.engine.stopBehindTheRecordersBack()
        harness.engine.failNextStarts(1)

        harness.recorder.handleCaptureEvent(.configurationChanged)

        #expect(harness.recorder.state == .paused)
        #expect(harness.recorder.routeChangeMessage != nil)
        #expect(harness.sink.isPaused)

        harness.recorder.resume()
        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.isRunning)
    }

    @Test func eventsFromTheEngineReachTheRecorderOnTheMainActor() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        harness.engine.emit(.interruptionBegan)
        for _ in 0..<1_000 where harness.recorder.state == .recording {
            await Task.yield()
        }

        #expect(harness.recorder.state == .paused)
    }

    // MARK: - Stall retry

    @Test func resumingAfterACaptureStallRebuildsTheTapBeforeRestarting() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()

        #expect(harness.recorder.reportCaptureStall())
        #expect(harness.recorder.state == .paused)
        #expect(harness.recorder.captureFailure == .stalled)

        harness.recorder.resume()

        #expect(harness.recorder.state == .recording)
        #expect(harness.engine.count(.stop) == 1)
        #expect(harness.engine.count(.removeTap) == 1)
        #expect(harness.engine.count(.installTap) == 2)
        #expect(harness.engine.count(.reactivateSession) == 1)
        #expect(harness.engine.isRunning)
        // The latched failure stays on the recording even after a successful retry.
        #expect(harness.recorder.captureFailure == .stalled)
    }

    @Test func resumeAfterAWriteFailureIsRefusedUntilTheSinkRecovers() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try await harness.start()
        harness.sink.failWrites(fromCall: 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: FakeAudioCaptureEngine.builtInMic, frameCapacity: 16))
        buffer.frameLength = 16
        harness.sink.write(buffer)

        #expect(harness.recorder.pollSinkStatus())
        #expect(harness.recorder.state == .paused)

        harness.recorder.resume()

        #expect(harness.recorder.state == .paused)
        #expect(harness.engine.count(.start) == 1)
        let result = try #require(harness.recorder.stop())
        #expect(result.captureFailure == .write)
    }
}

private final class TransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AudioRecorderState] = []

    func append(_ state: AudioRecorderState) {
        lock.withLock { states.append(state) }
    }

    var values: [AudioRecorderState] {
        lock.withLock { states }
    }
}

private final class HighlightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var highlights: [Highlight] = []

    func append(_ highlight: Highlight) {
        lock.withLock { highlights.append(highlight) }
    }

    var values: [Highlight] {
        lock.withLock { highlights }
    }
}
