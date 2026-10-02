//
//  DocumentGenerationViewModelTests.swift
//  KurnTests
//
//  `DocumentGenerationViewModel.generate` over an in-memory store with a
//  scripted LLM: meetings without transcript text are refused before the
//  provider, a reply becomes a persisted `GeneratedDocument` snapshotting its
//  sources, and each kind of failure lands in `error` the way the view reads it.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct DocumentGenerationViewModelTests {

    private struct ProviderDown: Error {}

    @MainActor
    private struct Harness {
        let context: ModelContext
        let llm: ScriptedLLMProvider
        let settings: AppSettings
        let viewModel: DocumentGenerationViewModel

        init(reply: @escaping @Sendable (Int) throws -> String = { _ in "# Launch brief\n\nWe ship on monday." }) {
            context = ModelContext(TestModelContainer.make())
            let llm = ScriptedLLMProvider(chat: { _, index in try reply(index) })
            self.llm = llm
            settings = MeetingFixtures.isolatedSettings()
            viewModel = DocumentGenerationViewModel(
                modelContext: context,
                service: DocumentGenerationService(resolveProvider: { _, _ in llm })
            )
        }

        func generate(_ meetings: [Meeting], prompt: String = "  Write a launch brief  ") async -> GeneratedDocument? {
            await viewModel.generate(
                meetings: meetings,
                prompt: prompt,
                sourceKind: .transcripts,
                sourceNames: meetings.map(\.title),
                settings: settings
            )
        }
    }

    @Test func aReplyBecomesAPersistedDocumentSnapshottingItsSources() async throws {
        let harness = Harness()
        let planning = MeetingFixtures.transcribed("Planning", in: harness.context)
        let review = MeetingFixtures.transcribed("Review", lines: ["numbers look fine"], in: harness.context)
        let empty = Meeting(title: "Empty")
        harness.context.insert(empty)

        let document = try #require(await harness.generate([planning, empty, review]))

        #expect(document.title == "Launch brief")
        #expect(document.userPrompt == "Write a launch brief")
        #expect(document.sourceMeetingIDs == [planning.id, review.id])
        #expect(document.sourceNames == ["Planning", "Empty", "Review"])
        #expect(!harness.viewModel.isGenerating)
        #expect(harness.viewModel.progress == nil)
        #expect(harness.viewModel.error == nil)
        let stored = try harness.context.fetch(FetchDescriptor<GeneratedDocument>())
        #expect(stored.count == 1)
        let prompt = harness.llm.chatCalls.first?.messages.first?.content ?? ""
        #expect(prompt.contains("we ship on monday"))
        #expect(prompt.contains("numbers look fine"))
    }

    @Test func meetingsWithoutTranscriptsAreRefusedBeforeTheProvider() async throws {
        let harness = Harness()
        let empty = Meeting(title: "Empty")
        harness.context.insert(empty)

        #expect(await harness.generate([empty]) == nil)

        guard case .documentGenerationFailed = harness.viewModel.error else {
            Issue.record("expected the no-transcripts error")
            return
        }
        #expect(harness.llm.chatCalls.isEmpty)
        #expect(!harness.viewModel.isGenerating)
    }

    @Test func aBlankPromptSurfacesTheServicesAppError() async throws {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)

        #expect(await harness.generate([meeting], prompt: "   ") == nil)

        guard case .documentGenerationFailed = harness.viewModel.error else {
            Issue.record("expected the empty-prompt error")
            return
        }
        #expect(harness.llm.chatCalls.isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<GeneratedDocument>()).isEmpty)
    }

    @Test func aNonAppErrorIsWrappedAsADocumentGenerationFailure() async throws {
        let harness = Harness(reply: { _ in throw ProviderDown() })
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)

        #expect(await harness.generate([meeting]) == nil)

        guard case .documentGenerationFailed = harness.viewModel.error else {
            Issue.record("expected the wrapped provider failure")
            return
        }
        #expect(try harness.context.fetch(FetchDescriptor<GeneratedDocument>()).isEmpty)
    }

    @Test func anAppErrorFromTheProviderSurfacesUnchanged() async throws {
        let harness = Harness(reply: { _ in throw AppError.noAPIKey(provider: "OpenAI") })
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)

        #expect(await harness.generate([meeting]) == nil)

        guard case .noAPIKey = harness.viewModel.error else {
            Issue.record("expected the provider's AppError")
            return
        }
    }

    @Test func cancellationIsSilent() async throws {
        let harness = Harness(reply: { _ in throw CancellationError() })
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)

        #expect(await harness.generate([meeting]) == nil)

        #expect(harness.viewModel.error == nil)
        #expect(!harness.viewModel.isGenerating)
    }
}
