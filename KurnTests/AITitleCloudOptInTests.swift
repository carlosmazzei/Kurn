//
//  AITitleCloudOptInTests.swift
//  KurnTests
//
//  An automatic AI title sends the whole transcript to the summary provider,
//  so with a cloud provider it waits for `AppSettings.aiTitleCloudEnabled`.
//  On-device generation and an explicit regenerate are never gated.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AITitleCloudOptInTests {

    @Test func onlyAnAutomaticCloudTitleNeedsTheOptIn() {
        let cloud = AIProvider.openAI
        let local = AIProvider.appleOnDevice
        #expect(!AITitleCoordinator.allowsGeneration(trigger: .automatic, provider: cloud, cloudEnabled: false))
        #expect(AITitleCoordinator.allowsGeneration(trigger: .automatic, provider: cloud, cloudEnabled: true))
        #expect(AITitleCoordinator.allowsGeneration(trigger: .explicit, provider: cloud, cloudEnabled: false))
        #expect(AITitleCoordinator.allowsGeneration(trigger: .automatic, provider: local, cloudEnabled: false))
    }

    @Test func theOptInIsOffByDefault() {
        #expect(MeetingFixtures.isolatedSettings().aiTitleCloudEnabled == false)
    }

    @Test func aCloudProviderIsNotSentTheTranscriptAutomaticallyUntilOptedIn() async {
        let context = ModelContext(TestModelContainer.make())
        let llm = ScriptedLLMProvider(summarize: { _, _ in
            SummaryResult(sections: [SummarySection(title: "Roadmap", body: "")])
        })
        let settings = MeetingFixtures.isolatedSettings()
        settings.aiProviderID = AIProvider.openAI.id
        let coordinator = AITitleCoordinator(
            summaryService: SummaryService(resolveProvider: { _, _ in llm }),
            providerCircuitBreaker: MeetingFixtures.freshCircuit(),
            isProviderUsable: { _ in true }
        )
        let meeting = MeetingFixtures.transcribed("Untitled", in: context)

        #expect(await coordinator.generateTitle(for: meeting, settings: settings) == nil)
        #expect(llm.summarizeCalls.isEmpty)

        let explicit = await coordinator.generateTitle(for: meeting, settings: settings, trigger: .explicit)
        #expect(explicit == "Roadmap")

        settings.aiTitleCloudEnabled = true
        let automatic = await coordinator.generateTitle(for: meeting, settings: settings, force: true)
        #expect(automatic == "Roadmap")
        #expect(llm.summarizeCalls.count == 2)
    }
}
