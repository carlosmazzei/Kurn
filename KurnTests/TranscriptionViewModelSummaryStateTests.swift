//
//  TranscriptionViewModelSummaryStateTests.swift
//  KurnTests
//
//  `TranscriptionViewModel.startSummary`/`cancelSummary` over a
//  `SummaryService` whose LLM is a scripted `LLMProvider` (no keychain, no
//  network): the `isSummarizing`/`isCancellingSummary` flags, what gets
//  persisted on success, how a provider failure surfaces, that cancellation
//  is silent, and that a run with no transcript text never reaches the LLM.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("TranscriptionViewModel summary state")
struct TranscriptionViewModelSummaryStateTests {

    private final class ScriptedLLM: LLMProvider, @unchecked Sendable {
        let provider: AIProvider = .openAI
        private let lock = NSLock()
        private var _calls = 0
        private var _failure: Error?
        private var _holds = false

        var calls: Int { lock.withLock { _calls } }
        func fail(with error: Error) { lock.withLock { _failure = error } }
        func holdUntilCancelled() { lock.withLock { _holds = true } }

        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
            let (failure, holds) = lock.withLock {
                _calls += 1
                return (_failure, _holds)
            }
            if holds { try await Task.sleep(for: .seconds(3_600)) }
            if let failure { throw failure }
            return SummaryResult(sections: [SummarySection(title: "Decisions", items: ["ship it"])])
        }

        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            throw AppError.transcriptionFailed("chat is not scripted")
        }
    }

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let llm: ScriptedLLM
        let viewModel: TranscriptionViewModel
        let meeting: Meeting

        init(withTranscript: Bool = true) throws {
            container = TestModelContainer.make()
            context = container.mainContext
            llm = ScriptedLLM()
            let scripted = llm
            viewModel = TranscriptionViewModel(
                modelContext: context,
                summaryService: SummaryService(resolveProvider: { _, _ in scripted })
            )
            meeting = Meeting(title: "Summary")
            context.insert(meeting)
            let recording = Recording(meeting: meeting, fileName: "s.m4a", duration: 12, transcriptionStatus: .done)
            context.insert(recording)
            if withTranscript {
                let transcript = Transcript(
                    recording: recording,
                    segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "we ship")],
                    language: "en"
                )
                context.insert(transcript)
                recording.transcript = transcript
            }
            try context.save()
        }

        func start() {
            viewModel.startSummary(for: meeting, provider: .openAI, model: "gpt-4o", template: .general)
        }

        func awaitSummary() async {
            await viewModel.summaryTask?.value
        }

        func waitUntilLLMCalled() async {
            for _ in 0..<2_000 where llm.calls == 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test func successPersistsASummaryAndClearsTheRunFlags() async throws {
        let harness = try Harness()

        harness.start()
        #expect(harness.viewModel.isSummarizing)
        await harness.awaitSummary()

        #expect(!harness.viewModel.isSummarizing)
        #expect(!harness.viewModel.isCancellingSummary)
        #expect(harness.viewModel.summaryTask == nil)
        #expect(harness.viewModel.error == nil)
        #expect(harness.meeting.summaries.count == 1)
        #expect(harness.meeting.summaries.first?.sections.first?.items == ["ship it"])
        #expect(harness.meeting.summaries.first?.provider == .openAI)
        #expect(harness.meeting.summaries.first?.model == "gpt-4o")
        #expect(harness.meeting.summaryMapCheckpointData == nil)
        #expect(harness.llm.calls == 1)
    }

    @Test func providerFailureSurfacesTheAppErrorAndPersistsNothing() async throws {
        let harness = try Harness()
        harness.llm.fail(with: AppError.noAPIKey(provider: "OpenAI"))

        harness.start()
        await harness.awaitSummary()

        guard case .noAPIKey = harness.viewModel.error else {
            Issue.record("expected the provider's AppError to surface")
            return
        }
        #expect(!harness.viewModel.isSummarizing)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func nonAppErrorIsWrappedAsAnAPIError() async throws {
        let harness = try Harness()
        harness.llm.fail(with: URLError(.badServerResponse))

        harness.start()
        await harness.awaitSummary()

        guard case .apiError(let statusCode, _) = harness.viewModel.error else {
            Issue.record("expected an apiError wrapper")
            return
        }
        #expect(statusCode == 0)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func meetingWithoutTranscriptFailsBeforeReachingTheLLM() async throws {
        let harness = try Harness(withTranscript: false)

        harness.start()
        await harness.awaitSummary()

        guard case .transcriptionFailed = harness.viewModel.error else {
            Issue.record("expected the no-transcript error")
            return
        }
        #expect(harness.llm.calls == 0)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func cancelIsSilentAndPersistsNothing() async throws {
        let harness = try Harness()
        harness.llm.holdUntilCancelled()

        harness.start()
        await harness.waitUntilLLMCalled()
        harness.viewModel.cancelSummary()
        #expect(harness.viewModel.isCancellingSummary)
        await harness.awaitSummary()

        #expect(!harness.viewModel.isSummarizing)
        #expect(!harness.viewModel.isCancellingSummary)
        #expect(harness.viewModel.error == nil)
        #expect(harness.meeting.summaries.isEmpty)
    }

    @Test func secondStartWhileRunningIsIgnoredAndCancelWithoutRunIsANoOp() async throws {
        let harness = try Harness()
        harness.viewModel.cancelSummary()
        #expect(!harness.viewModel.isCancellingSummary)

        harness.llm.holdUntilCancelled()
        harness.start()
        await harness.waitUntilLLMCalled()
        let first = harness.viewModel.summaryTask
        harness.start()
        #expect(harness.viewModel.summaryTask == first)

        harness.viewModel.cancelSummary()
        await harness.awaitSummary()
        #expect(harness.llm.calls == 1)
    }
}
