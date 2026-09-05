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
        while !viewModel.hasPendingMicChoiceContinuationForTesting, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(viewModel.hasPendingMicChoiceContinuationForTesting)

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
        #expect(!viewModel.hasPendingMicChoiceContinuationForTesting)
    }
}
#endif
