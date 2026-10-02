//
//  SummaryTranslationTests.swift
//  KurnTests
//
//  `SummaryViewModel.startTranslateSummary` with a scripted LLM: a
//  translation is a new `Summary` beside the original (never an edit of it),
//  labelled with the source template and target language, and every failure
//  path leaves the run flags cleared and nothing persisted.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SummaryTranslationTests {

    private struct ProviderDown: Error {}

    @MainActor
    private struct Harness {
        let context: ModelContext
        let llm: ScriptedLLMProvider
        let viewModel: SummaryViewModel
        let meeting: Meeting
        let source: Summary

        init(
            templateName: String? = "General",
            sections: [SummarySection] = [SummarySection(title: "Decisions", items: ["ship it"])],
            reply: @escaping @Sendable (Int) throws -> SummaryResult = { _ in
                SummaryResult(sections: [SummarySection(title: "Decisões", items: ["lançar"])])
            }
        ) throws {
            context = ModelContext(TestModelContainer.make())
            let llm = ScriptedLLMProvider(summarize: { _, index in try reply(index) })
            self.llm = llm
            viewModel = SummaryViewModel(
                modelContext: context,
                summaryService: SummaryService(resolveProvider: { _, _ in llm })
            )
            meeting = MeetingFixtures.transcribed("Planning", in: context)
            source = Summary(meeting: meeting, sections: sections, templateName: templateName, provider: .openAI, model: "gpt-4o")
            context.insert(source)
            try context.save()
        }

        func translate(to language: MeetingLanguage = .portuguese) async {
            viewModel.startTranslateSummary(
                source: source,
                meeting: meeting,
                targetLanguage: language,
                provider: .openAI,
                model: "gpt-4o"
            )
            await viewModel.translationTask?.value
        }

        var translations: [Summary] {
            meeting.summaries.filter { $0.id != source.id }
        }
    }

    @Test func aTranslationIsANewSummaryLabelledWithTemplateAndLanguage() async throws {
        let harness = try Harness()

        harness.viewModel.startTranslateSummary(
            source: harness.source,
            meeting: harness.meeting,
            targetLanguage: .portuguese,
            provider: .openAI,
            model: "gpt-4o"
        )
        #expect(harness.viewModel.isTranslatingSummary)
        #expect(harness.viewModel.translatingSummaryID == harness.source.id)
        #expect(harness.viewModel.translationTargetLanguage == .portuguese)
        await harness.viewModel.translationTask?.value

        let translated = try #require(harness.translations.first)
        #expect(harness.translations.count == 1)
        #expect(translated.templateName == "General (\(MeetingLanguage.portuguese.displayName))")
        #expect(translated.sections.first?.items == ["lançar"])
        #expect(translated.model == "gpt-4o")
        #expect(harness.source.sections.first?.items == ["ship it"])
        #expect(!harness.viewModel.isTranslatingSummary)
        #expect(harness.viewModel.translatingSummaryID == nil)
        #expect(harness.viewModel.translationTargetLanguage == nil)
        #expect(harness.viewModel.translationTask == nil)
        #expect(harness.viewModel.error == nil)
        #expect(harness.llm.summarizeCalls.first?.userPrompt.contains("ship it") == true)
    }

    @Test func withoutATemplateTheLabelIsTheLanguageAlone() async throws {
        let harness = try Harness(templateName: nil)
        await harness.translate(to: .spanish)
        #expect(harness.translations.first?.templateName == MeetingLanguage.spanish.displayName)
    }

    @Test func anEmptySourceFailsBeforeTheProvider() async throws {
        let harness = try Harness(sections: [])
        await harness.translate()
        guard case .summaryTranslationFailed = harness.viewModel.error else {
            Issue.record("expected the empty-source error")
            return
        }
        #expect(harness.llm.summarizeCalls.isEmpty)
        #expect(harness.translations.isEmpty)
        #expect(!harness.viewModel.isTranslatingSummary)
    }

    @Test func anAppErrorSurfacesUnchanged() async throws {
        let harness = try Harness(reply: { _ in throw AppError.noAPIKey(provider: "OpenAI") })
        await harness.translate()
        guard case .noAPIKey = harness.viewModel.error else {
            Issue.record("expected the provider's AppError")
            return
        }
        #expect(harness.translations.isEmpty)
    }

    @Test func aNonAppErrorIsWrappedAsAnAPIError() async throws {
        let harness = try Harness(reply: { _ in throw ProviderDown() })
        await harness.translate()
        guard case .apiError(let statusCode, _) = harness.viewModel.error else {
            Issue.record("expected an apiError wrapper")
            return
        }
        #expect(statusCode == 0)
        #expect(harness.translations.isEmpty)
    }

    @Test func cancellationIsSilentAndCancelWithoutARunIsANoOp() async throws {
        let harness = try Harness(reply: { _ in throw CancellationError() })
        harness.viewModel.cancelTranslateSummary()
        await harness.translate()
        #expect(harness.viewModel.error == nil)
        #expect(harness.translations.isEmpty)
    }

    @Test func aSecondStartWhileTranslatingIsIgnored() async throws {
        let harness = try Harness()
        harness.viewModel.isTranslatingSummary = true
        harness.viewModel.startTranslateSummary(
            source: harness.source,
            meeting: harness.meeting,
            targetLanguage: .portuguese,
            provider: .openAI,
            model: "gpt-4o"
        )
        #expect(harness.viewModel.translationTask == nil)
        #expect(harness.llm.summarizeCalls.isEmpty)
    }
}
