//
//  MeetingChatViewModelReliabilityEventTests.swift
//  KurnTests
//
//  `MeetingChatViewModel.send` reports one "view_model"-stage `ReliabilityEvent` once the
//  whole user-visible round trip finishes. `task` is private, so this polls `isResponding`
//  for completion, and it passes its own `runID` to `send` and filters by it, since other
//  suites report concurrent "meeting_chat" events.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelReliabilityEventTests {
    private func waitUntilDone(_ viewModel: MeetingChatViewModel) async {
        for _ in 0..<2_000 where viewModel.isResponding {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: [false, true])
    func sendReportsOneViewModelStageEventMatchingOutcome(answers: Bool) async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }

        let runID = OperationID()
        let model: (any AgentModel)? = answers ? ChatAgentModel([AgentTurnResponse(text: "Decided.")]) : nil
        let viewModel = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        let context = ModelContext(TestModelContainer.make())
        viewModel.configure(meeting: MeetingFixtures.transcribed("Planning", in: context), modelContext: context)
        viewModel.send(question: "What was decided?", provider: answers ? .openAI : .appleOnDevice,
                       model: answers ? "gpt-4o" : "", runID: runID)
        await waitUntilDone(viewModel)

        let events = capture.recorded.filter { $0.operationID == runID && $0.stage == "view_model" }
        #expect(events.count == 1)
        #expect(!viewModel.isResponding)
        #expect(events.first?.outcome == (answers ? .succeeded : .failed))
        #expect((events.first?.code == nil) == answers)
        #expect((viewModel.error == nil) == answers)
    }
}
