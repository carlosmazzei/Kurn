//
//  AITitleCoordinatorGenerationTests.swift
//  KurnTests
//
//  `AITitleCoordinator.generateTitle` over an in-memory store with a scripted
//  LLM: the title comes back from the model's first section, the skip
//  conditions never reach the provider, an explicit failure surfaces in
//  `lastError` while an automatic one stays silent, and a failure opens the
//  provider circuit for the next automatic attempt.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AITitleCoordinatorGenerationTests {

    private struct ProviderDown: Error {}

    @MainActor
    private struct Harness {
        let context: ModelContext
        let llm: ScriptedLLMProvider
        let settings: AppSettings
        let coordinator: AITitleCoordinator

        init(usable: Bool = true, reply: @escaping @Sendable (Int) throws -> SummaryResult = { _ in
            SummaryResult(sections: [SummarySection(title: "  Quarterly roadmap review  ", body: "")])
        }) {
            context = ModelContext(TestModelContainer.make())
            let llm = ScriptedLLMProvider(summarize: { _, index in try reply(index) })
            self.llm = llm
            settings = MeetingFixtures.isolatedSettings()
            coordinator = AITitleCoordinator(
                summaryService: SummaryService(resolveProvider: { _, _ in llm }),
                providerCircuitBreaker: MeetingFixtures.freshCircuit(),
                isProviderUsable: { _ in usable }
            )
        }
    }

    @Test func theTitleIsTheTrimmedFirstSectionTitle() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Untitled", in: harness.context)
        let title = await harness.coordinator.generateTitle(for: meeting, settings: harness.settings)
        #expect(title == "Quarterly roadmap review")
        #expect(harness.coordinator.generatingMeetingIDs.isEmpty)
        #expect(harness.coordinator.lastError == nil)
        #expect(harness.llm.summarizeCalls.first?.userPrompt.contains("we ship on monday") == true)
    }

    @Test func anExistingTitleIsKeptUnlessForced() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Untitled", in: harness.context)
        meeting.aiTitle = "Already named"
        #expect(await harness.coordinator.generateTitle(for: meeting, settings: harness.settings) == nil)
        #expect(harness.llm.summarizeCalls.isEmpty)
        let forced = await harness.coordinator.generateTitle(for: meeting, settings: harness.settings, force: true)
        #expect(forced == "Quarterly roadmap review")
    }

    @Test func noTranscriptOrUnusableProviderNeverReachesTheLLM() async {
        let harness = Harness()
        let empty = Meeting(title: "Empty")
        harness.context.insert(empty)
        #expect(await harness.coordinator.generateTitle(for: empty, settings: harness.settings) == nil)

        let unusable = Harness(usable: false)
        let meeting = MeetingFixtures.transcribed("Untitled", in: unusable.context)
        #expect(await unusable.coordinator.generateTitle(for: meeting, settings: unusable.settings) == nil)
        #expect(harness.llm.summarizeCalls.isEmpty)
        #expect(unusable.llm.summarizeCalls.isEmpty)
    }

    @Test func anExplicitFailureSurfacesInLastError() async {
        let harness = Harness(reply: { _ in throw ProviderDown() })
        let meeting = MeetingFixtures.transcribed("Untitled", in: harness.context)
        let title = await harness.coordinator.generateTitle(
            for: meeting, settings: harness.settings, trigger: .explicit
        )
        #expect(title == nil)
        guard case .titleGenerationFailed = harness.coordinator.lastError else {
            Issue.record("expected a non-AppError to be wrapped as titleGenerationFailed")
            return
        }
    }

    @Test func anEmptyModelTitleIsADecodingErrorWhenExplicit() async {
        let harness = Harness(reply: { _ in SummaryResult(sections: [SummarySection(title: "   ", body: "")]) })
        let meeting = MeetingFixtures.transcribed("Untitled", in: harness.context)
        _ = await harness.coordinator.generateTitle(for: meeting, settings: harness.settings, trigger: .explicit)
        guard case .decodingError = harness.coordinator.lastError else {
            Issue.record("expected the empty-title AppError to surface unchanged")
            return
        }
    }

    @Test func anAutomaticFailureIsSilentAndOpensTheCircuit() async {
        let harness = Harness(reply: { index in
            if index == 0 { throw ProviderDown() }
            return SummaryResult(sections: [SummarySection(title: "Recovered", body: "")])
        })
        let meeting = MeetingFixtures.transcribed("Untitled", in: harness.context)
        #expect(await harness.coordinator.generateTitle(for: meeting, settings: harness.settings) == nil)
        #expect(harness.coordinator.lastError == nil)

        // The transient failure blocks the next automatic attempt…
        #expect(await harness.coordinator.generateTitle(for: meeting, settings: harness.settings) == nil)
        #expect(harness.llm.summarizeCalls.count == 1)

        // …but an explicit retry always goes through.
        let title = await harness.coordinator.generateTitle(
            for: meeting, settings: harness.settings, trigger: .explicit
        )
        #expect(title == "Recovered")
    }
}
