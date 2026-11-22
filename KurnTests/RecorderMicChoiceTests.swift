//
//  RecorderMicChoiceTests.swift
//  KurnTests
//
//  H8 PR 18: `RecorderViewModel.prepareToRecord()` used to store a pending
//  mic-choice `CheckedContinuation` in a plain property with no protection
//  against a second concurrent request overwriting it — silently leaking
//  the first continuation, which nothing would ever resume, hanging that
//  earlier `prepareToRecord()` call forever. `storeMicChoiceContinuation(_:)`
//  now resolves any already-pending continuation (to `nil`, "use the system
//  default") before storing a new one.
//
//  Drives `storeMicChoiceContinuation(_:)` directly rather than through
//  `prepareToRecord()` itself: the real trigger
//  (`AVAudioSession.availableInputs.count > 1`) isn't reproducible against
//  the simulator's single built-in mic.
//

import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Kurn

// Exercises DEBUG-only test hooks; the Release-configuration lane
// compiles KurnTests without DEBUG, so this suite is absent there.
#if DEBUG

@MainActor
struct RecorderMicChoiceTests {

    @Test func secondPendingMicChoiceResolvesTheFirstToTheDefaultInsteadOfLeakingIt() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try context.save()
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context, defaultMode: .onDevice)

        let firstResultTask = Task { @MainActor () -> String? in
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                viewModel.storeMicChoiceContinuation(continuation)
            }
        }

        // Poll (bounded, no fixed sleep) until the first continuation is
        // actually stored before simulating a second concurrent request.
        var attempts = 0
        while !viewModel.hasPendingMicChoiceForTesting, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(viewModel.hasPendingMicChoiceForTesting)

        // A second mic-choice request arrives while the first is still
        // pending — storing it must resolve the first to `nil` rather than
        // silently overwriting and leaking it.
        let secondResult = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            viewModel.storeMicChoiceContinuation(continuation)
            viewModel.chooseMic(uid: "second-choice")
        }

        let firstResult = await firstResultTask.value
        #expect(firstResult == nil) // auto-resolved to the default, never left hanging
        #expect(secondResult == "second-choice") // the second request still resolves normally
    }

    @Test func normalChooseMicResolvesTheOnlyPendingContinuation() async {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context, defaultMode: .onDevice)

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            viewModel.storeMicChoiceContinuation(continuation)
            viewModel.chooseMic(uid: "built-in")
        }

        #expect(result == "built-in")
        #expect(!viewModel.hasPendingMicChoiceForTesting)
    }

    /// Cancelling the chooser resolves a pending continuation but must not
    /// rewrite the stored preference or touch a live route — dismissing is
    /// not a choice.
    @Test func dismissMicChoicesResolvesTheContinuationWithoutChangingThePreference() async {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context, defaultMode: .onDevice)
        viewModel.chooseMic(uid: "kept-choice")
        #expect(viewModel.recorder.preferredInputUID == "kept-choice")

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            viewModel.storeMicChoiceContinuation(continuation)
            viewModel.dismissMicChoices()
        }

        #expect(result == nil)
        #expect(viewModel.recorder.preferredInputUID == "kept-choice")
        #expect(!viewModel.hasPendingMicChoiceForTesting)
    }

    /// `alwaysUseBuiltInMic` keeps the mic button inert: the picker never
    /// opens (and so never switches the session category or enumerates
    /// Bluetooth inputs) and the view can disable it via `micPickerDisabled`.
    @Test func alwaysUseBuiltInMicSkipsTheChooser() {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice,
            options: RecorderOptions(alwaysUseBuiltInMic: true)
        )

        #expect(viewModel.micPickerDisabled)
        viewModel.presentMicChoices()
        #expect(viewModel.micChoices.isEmpty)
    }

    @Test func dismissMicChoicesWithoutAPendingContinuationIsANoOp() {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context, defaultMode: .onDevice)
        viewModel.recorder.preferredInputUID = "kept-choice"

        viewModel.dismissMicChoices()

        #expect(viewModel.recorder.preferredInputUID == "kept-choice")
        #expect(!viewModel.hasPendingMicChoiceForTesting)
    }

    /// Picking a mic while a capture is live routes it straight to the audio
    /// session (`applyPreferredInput`); the pick still lands on the service's
    /// stored preference for the next start.
    @Test func chooseMicDuringACaptureAppliesTheLiveRoute() async throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let service = AudioRecorderService(engine: FakeAudioCaptureEngine(),
                                           sink: FakeAudioSinkWriting(), stallInterval: 3_600,
                                           microphonePermission: { true })
        try await service.start(fileName: "mic-live-\(UUID().uuidString).m4a")
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context,
                                        defaultMode: .onDevice, recorder: service)

        viewModel.chooseMic(uid: "live-choice")

        #expect(service.preferredInputUID == "live-choice")
        #expect(service.state == .recording)
        _ = service.stop()
    }

    @Test func localizedMicNameCoversEachPortType() {
        #expect(RecorderViewModel.localizedMicName(for: .builtInMic)?.isEmpty == false)
        #expect(RecorderViewModel.localizedMicName(for: .bluetoothHFP)?.isEmpty == false)
        #expect(RecorderViewModel.localizedMicName(for: .bluetoothLE)?.isEmpty == false)
        #expect(RecorderViewModel.localizedMicName(for: .headsetMic)?.isEmpty == false)
        #expect(RecorderViewModel.localizedMicName(for: .usbAudio)?.isEmpty == false)
        #expect(RecorderViewModel.localizedMicName(for: .lineIn) == nil)
    }

    /// Reads the routed input name off the shared session — on the simulator
    /// that's the built-in mic, whose raw `portName` is the type id and so
    /// falls back to the localized stand-in.
    @Test func currentMicNameReadsTheLiveSessionRoute() {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Mic choice")
        context.insert(meeting)
        try? context.save()
        let viewModel = RecorderViewModel(meeting: meeting, modelContext: context, defaultMode: .onDevice)

        if let name = viewModel.currentMicName {
            #expect(!name.isEmpty)
        }
    }
}
#endif
