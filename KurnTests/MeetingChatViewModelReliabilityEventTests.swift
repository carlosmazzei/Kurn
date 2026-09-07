//
//  MeetingChatViewModelReliabilityEventTests.swift
//  KurnTests
//
//  `MeetingChatViewModel.send` reports its own "view_model"-stage
//  `ReliabilityEvent` once the whole user-visible round trip finishes,
//  distinct from `MeetingChatService`'s own per-stage events — the same
//  two-tier shape `DocumentGenerationViewModel`/`DocumentGenerationService`
//  use. Unlike `MeetingChatReliabilityEventTests` (which calls the service
//  directly and can pass its own `runID`), `send` generates its `runID`
//  internally and `task` is private, so this filters loosely by
//  operation/stage and polls `isResponding` instead — the same constraint
//  already documented for `TranscriptionViewModelSummaryStateTests`'
//  `waitUntilLLMCalled()`. Marked `.serialized` because that loose filter
//  would otherwise also pick up another parallel test's own
//  "meeting_chat"/"view_model" events.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
@Suite(.serialized)
struct MeetingChatViewModelReliabilityEventTests {

    private func waitUntilDone(_ viewModel: MeetingChatViewModel) async {
        for _ in 0..<2_000 where viewModel.isResponding {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Same defensive shape as
    /// `MeetingChatReliabilityEventTests.appleOnDeviceProviderResolutionReliabilityMatchesAvailability`,
    /// and for the same reason that test only asserts its deterministic
    /// branch: when the device reports itself available, `send` goes on to a
    /// real on-device generation call whose outcome CI has shown can be a
    /// `LanguageModelSession.GenerationError` even then — not something this
    /// test can predict. Only the "unavailable" branch (deterministic:
    /// resolution fails with `.onDeviceModelUnavailable`, reported as one
    /// failed "view_model" event) is asserted.
    @Test func sendReportsOneViewModelStageEventMatchingOutcome() async {
        let reason = OnDeviceModelAvailability.unavailableReason
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }

        let viewModel = MeetingChatViewModel()
        viewModel.send(
            question: "What was decided?",
            transcriptText: nil,
            candidates: [],
            provider: .appleOnDevice,
            model: ""
        )
        await waitUntilDone(viewModel)

        let events = capture.recorded.filter { $0.operation == "meeting_chat" && $0.stage == "view_model" }
        #expect(events.count == 1)
        guard reason != nil else { return }
        #expect(events.first?.outcome == .failed)
        #expect(events.first?.code == "on_device_model_unavailable")
        #expect(viewModel.error != nil)
    }
}
