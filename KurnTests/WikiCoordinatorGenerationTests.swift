//
//  WikiCoordinatorGenerationTests.swift
//  KurnTests
//
//  `WikiCoordinator` end to end over an in-memory store with a scripted LLM:
//  an article is built, kept when nothing changed, replaced in place when
//  forced, left alone when the provider fails, and the backfill and bulk
//  runs pick the meetings they should.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct WikiCoordinatorGenerationTests {

    private struct ProviderDown: Error {}

    @MainActor
    private struct Harness {
        let context: ModelContext
        let llm: ScriptedLLMProvider
        let settings: AppSettings
        let coordinator: WikiCoordinator

        init(usable: Bool = true, enabled: Bool = true, failing: Bool = false) {
            context = ModelContext(TestModelContainer.make())
            let llm = ScriptedLLMProvider(summarize: { _, index in
                if failing { throw ProviderDown() }
                return SummaryResult(sections: [SummarySection(title: "Decisions", items: ["decision \(index)"])])
            })
            self.llm = llm
            settings = MeetingFixtures.isolatedSettings()
            settings.wikiEnabled = enabled
            coordinator = WikiCoordinator(
                modelContext: context,
                appSettings: settings,
                providerCircuitBreaker: MeetingFixtures.freshCircuit(),
                wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm })),
                isProviderUsable: { _ in usable }
            )
        }
    }

    // MARK: - Single meeting

    @Test func generatingBuildsAnArticleFromTheTranscript() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        let outcome = await harness.coordinator.generate(meeting)
        #expect(outcome == .generated)
        let article = meeting.wikiArticle
        #expect(article?.bodyMarkdown.contains("decision 0") == true)
        #expect(article?.meetingTitleSnapshot == "Planning")
        #expect(harness.coordinator.articleCount() == 1)
        #expect(harness.coordinator.generatingMeetingIDs.isEmpty)
        #expect(harness.llm.summarizeCalls.first?.userPrompt.contains("we ship on monday") == true)
    }

    @Test func anUpToDateArticleIsNotRegenerated() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        await harness.coordinator.generate(meeting)
        #expect(await harness.coordinator.generate(meeting) == .skipped)
        #expect(harness.llm.summarizeCalls.count == 1)
    }

    @Test func forcingReplacesTheArticleInPlace() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        await harness.coordinator.generate(meeting)
        let first = meeting.wikiArticle
        #expect(await harness.coordinator.generate(meeting, force: true) == .generated)
        #expect(meeting.wikiArticle === first)
        #expect(meeting.wikiArticle?.bodyMarkdown.contains("decision 1") == true)
        #expect(harness.coordinator.articleCount() == 1)
    }

    @Test func aMeetingWithoutTranscriptOrSettingsIsSkipped() async {
        let harness = Harness()
        let empty = Meeting(title: "Empty")
        harness.context.insert(empty)
        #expect(await harness.coordinator.generate(empty) == .skipped)

        let unconfigured = WikiCoordinator(modelContext: harness.context)
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        #expect(await unconfigured.generate(meeting) == .skipped)
        #expect(harness.llm.summarizeCalls.isEmpty)
    }

    @Test func anExplicitFailureSurfacesAndKeepsNoArticle() async {
        let harness = Harness(failing: true)
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        #expect(await harness.coordinator.generate(meeting, trigger: .explicit) == .failed)
        #expect(meeting.wikiArticle == nil)
        #expect(harness.coordinator.lastError != nil)
    }

    @Test func anAutomaticFailureStaysSilent() async {
        let harness = Harness(failing: true)
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        #expect(await harness.coordinator.generate(meeting) == .failed)
        #expect(harness.coordinator.lastError == nil)
    }

    // MARK: - Backfill and bulk runs

    @Test func backfillBuildsMissingArticles() async {
        let harness = Harness()
        MeetingFixtures.transcribed("A", in: harness.context)
        MeetingFixtures.transcribed("B", in: harness.context)
        harness.context.insert(Meeting(title: "No transcript"))
        await harness.coordinator.backfill()
        #expect(harness.coordinator.articleCount() == 2)
        #expect(!harness.coordinator.isBackfilling)
    }

    @Test func backfillIsBoundedPerActivation() async {
        let harness = Harness()
        for index in 0..<(WikiCoordinator.backfillBatchLimit + 2) {
            MeetingFixtures.transcribed("M\(index)", in: harness.context)
        }
        await harness.coordinator.backfill()
        #expect(harness.coordinator.articleCount() == WikiCoordinator.backfillBatchLimit)
    }

    @Test func theDefaultUsabilityCheckIsTheProvidersOwn() async {
        let context = ModelContext(TestModelContainer.make())
        let llm = ScriptedLLMProvider()
        let settings = MeetingFixtures.isolatedSettings()
        settings.wikiEnabled = true
        let coordinator = WikiCoordinator(
            modelContext: context,
            appSettings: settings,
            providerCircuitBreaker: MeetingFixtures.freshCircuit(),
            wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm }))
        )
        MeetingFixtures.transcribed("Planning", in: context)
        await coordinator.rebuildWiki()
        #expect(coordinator.articleCount() == (settings.aiProvider.isUsable ? 1 : 0))
    }

    @Test func backfillDoesNothingWhenDisabledOrUnusable() async {
        let disabled = Harness(enabled: false)
        MeetingFixtures.transcribed("A", in: disabled.context)
        await disabled.coordinator.backfill()
        #expect(disabled.coordinator.articleCount() == 0)

        let unusable = Harness(usable: false)
        MeetingFixtures.transcribed("A", in: unusable.context)
        await unusable.coordinator.backfill()
        await unusable.coordinator.rebuildWiki()
        await unusable.coordinator.generateMissing()
        #expect(unusable.coordinator.articleCount() == 0)
        #expect(unusable.llm.summarizeCalls.isEmpty)
    }

    @Test func backfillStopsAtTheFirstFailure() async {
        let harness = Harness(failing: true)
        MeetingFixtures.transcribed("A", in: harness.context)
        MeetingFixtures.transcribed("B", in: harness.context)
        await harness.coordinator.backfill()
        #expect(harness.llm.summarizeCalls.count == 1)
    }

    @Test func generateMissingSkipsUpToDateMeetings() async {
        let harness = Harness()
        let done = MeetingFixtures.transcribed("Done", in: harness.context)
        await harness.coordinator.generate(done)
        MeetingFixtures.transcribed("Missing", in: harness.context)
        await harness.coordinator.generateMissing()
        #expect(harness.llm.summarizeCalls.count == 2)
        #expect(harness.coordinator.articleCount() == 2)
        #expect(harness.coordinator.bulkOperation == nil)
    }

    @Test func rebuildRegeneratesEveryTranscribedMeeting() async {
        let harness = Harness()
        let done = MeetingFixtures.transcribed("Done", in: harness.context)
        await harness.coordinator.generate(done)
        MeetingFixtures.transcribed("Other", in: harness.context)
        await harness.coordinator.rebuildWiki()
        #expect(harness.llm.summarizeCalls.count == 3)
        #expect(harness.coordinator.articleCount() == 2)
    }

    @Test func clearingRemovesEveryArticle() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        await harness.coordinator.generate(meeting)
        harness.coordinator.clearWiki()
        #expect(harness.coordinator.articleCount() == 0)
        #expect(meeting.wikiArticle == nil)
    }
}
