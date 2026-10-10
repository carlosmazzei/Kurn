//
//  SummaryServiceGenerationTests.swift
//  KurnTests
//
//  `SummaryService` against a scripted LLM: the single-pass prompt, the staged
//  (map-reduce) path with its progress and durable checkpoints, title
//  generation and summary translation — including every reply that is
//  rejected rather than shown.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SummaryServiceGenerationTests {

    private struct ProviderDown: Error {}

    private func service(_ llm: ScriptedLLMProvider) -> SummaryService {
        SummaryService(resolveProvider: { _, _ in llm })
    }

    /// `[mm:ss] Speaker: …` lines past the on-device single-pass threshold.
    private func longTranscript(lines: Int = 300) -> String {
        (0..<lines).map { "[\(String(format: "%02d", $0 / 60)):\(String(format: "%02d", $0 % 60))] Speaker 1: line \($0) of a long meeting" }
            .joined(separator: "\n")
    }

    // MARK: - Single pass

    @Test func shortTranscriptIsOneRequestWithTitleAndTranscript() async throws {
        let llm = ScriptedLLMProvider()
        let result = try await service(llm).generate(
            transcriptText: "  [00:01] Ana: vamos começar  ",
            meetingTitle: "Planejamento",
            provider: .openAI,
            model: "m",
            template: .general
        )
        #expect(result.sections.first?.title == "Notes")
        let call = try #require(llm.summarizeCalls.first)
        #expect(llm.summarizeCalls.count == 1)
        #expect(call.systemPrompt == SummaryPrompt.system(for: .general))
        #expect(call.userPrompt.contains("Meeting title: Planejamento"))
        #expect(call.userPrompt.hasSuffix("[00:01] Ana: vamos começar"))
    }

    @Test func providerResolutionFailureSurfaces() async {
        let failing = SummaryService(resolveProvider: { _, _ in throw AppError.noAPIKey(provider: "OpenAI") })
        await #expect(throws: AppError.self) {
            _ = try await failing.generate(
                transcriptText: "texto", meetingTitle: "t", provider: .openAI, model: "m", template: .general
            )
        }
    }

    // MARK: - Staged

    @Test func longTranscriptIsCondensedInStagesThenReduced() async throws {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice) { call, index in
            SummaryResult(sections: [SummarySection(title: "Part", body: "notes \(index)")])
        }
        let progress = Recorded<String>()
        let checkpoints = Recorded<Int>()
        let transcript = longTranscript()
        let result = try await service(llm).generate(
            transcriptText: transcript,
            meetingTitle: "Longa",
            provider: .appleOnDevice,
            model: "on-device",
            template: .standup,
            onProgress: { stage, total in progress.append("\(stage)/\(total)") },
            onMapStageCompleted: { checkpoint in checkpoints.append(checkpoint.completedNotes.count) }
        )

        let blocks = SummaryService.splitTranscript(transcript, maxChars: ContextBudget.onDevice.mapBlockChars(for: transcript))
        #expect(blocks.count > 1)
        let calls = llm.summarizeCalls
        #expect(calls.count == blocks.count + 1)
        for call in calls.dropLast() {
            #expect(call.systemPrompt == SummaryPrompt.system(for: SummaryService.notesTemplate))
        }
        #expect(calls[0].userPrompt.contains("Transcript (part 1 of \(blocks.count)):"))
        let reduce = try #require(calls.last)
        #expect(reduce.systemPrompt == SummaryPrompt.system(for: .standup))
        #expect(reduce.userPrompt.contains("Part 1 of \(blocks.count):"))
        #expect(reduce.userPrompt.contains("notes 0"))
        #expect(progress.values.last == "\(blocks.count + 1)/\(blocks.count + 1)")
        #expect(checkpoints.values == Array(1...blocks.count))
        #expect(result.sections.first?.body == "notes \(blocks.count)")
    }

    @Test func aMatchingCheckpointSkipsTheBlocksAlreadyCondensed() async throws {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice)
        let transcript = longTranscript()
        let blocks = SummaryService.splitTranscript(transcript, maxChars: ContextBudget.onDevice.mapBlockChars(for: transcript))
        let resume = SummaryMapCheckpoint(
            contentDigest: SummaryService.contentDigest(transcript),
            providerID: AIProvider.appleOnDevice.id,
            model: "on-device",
            totalBlocks: blocks.count,
            completedNotes: ["earlier"]
        )
        _ = try await service(llm).generate(
            transcriptText: transcript,
            meetingTitle: "Longa",
            provider: .appleOnDevice,
            model: "on-device",
            template: .general,
            resume: resume
        )
        #expect(llm.summarizeCalls.count == blocks.count)
        #expect(llm.summarizeCalls.last?.userPrompt.contains("earlier") == true)
    }

    @Test func aFailedBlockAbortsTheWholeSummary() async {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice) { _, index in
            if index == 1 { throw ProviderDown() }
            return SummaryResult(sections: [SummarySection(title: "Part")])
        }
        await #expect(throws: ProviderDown.self) {
            _ = try await service(llm).generate(
                transcriptText: longTranscript(),
                meetingTitle: "Longa",
                provider: .appleOnDevice,
                model: "on-device",
                template: .general
            )
        }
        #expect(llm.summarizeCalls.count == 2)
    }

    // MARK: - Context budget

    /// ~100k characters: past the conservative budget, inside a 128k window.
    private var twoHourTranscript: String {
        String(repeating: "[12:34] Speaker 1: we agreed to ship it\n", count: 2_500)
    }

    private static var tooLong: AppError { .apiError(statusCode: 400, message: "This model's maximum context length is 128000 tokens.") }

    private func service(_ llm: ScriptedLLMProvider, budget: ContextBudget) -> SummaryService {
        SummaryService(resolveProvider: { _, _ in llm }, resolveBudget: { _, _ in budget })
    }

    @Test func aTranscriptInsideTheModelsWindowIsOneRequest() async throws {
        let llm = ScriptedLLMProvider()
        _ = try await service(llm, budget: .forContextWindow(128_000, reservedOutputTokens: 8_192)).generate(
            transcriptText: twoHourTranscript, meetingTitle: "Longa", provider: .openAI, model: "gpt-4o", template: .general
        )
        #expect(llm.summarizeCalls.count == 1)
        #expect(llm.summarizeCalls.first?.systemPrompt == SummaryPrompt.system(for: .general))
    }

    @Test func aRejectedSinglePassIsStagedWithTheConservativeBudget() async throws {
        let llm = ScriptedLLMProvider { _, index in
            if index == 0 { throw Self.tooLong }
            return SummaryResult(sections: [SummarySection(title: "Part", body: "notes \(index)")])
        }
        let transcript = twoHourTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await service(llm, budget: .forContextWindow(128_000, reservedOutputTokens: 8_192)).generate(
            transcriptText: transcript, meetingTitle: "Longa", provider: .openAI, model: "gpt-4o", template: .general
        )
        let blocks = SummaryService.splitTranscript(
            transcript, maxChars: ContextBudget.conservative.mapBlockChars(for: transcript)
        )
        #expect(blocks.count > 1)
        #expect(llm.summarizeCalls.count == 1 + blocks.count + 1)
        #expect(llm.summarizeCalls[1].systemPrompt == SummaryPrompt.system(for: SummaryService.notesTemplate))
    }

    @Test func aRejectionStagingCouldNotHelpSurfaces() async {
        let llm = ScriptedLLMProvider { _, _ in throw Self.tooLong }
        await #expect(throws: AppError.self) {
            _ = try await service(llm, budget: .forContextWindow(128_000, reservedOutputTokens: 8_192)).generate(
                transcriptText: "[00:01] Ana: curto", meetingTitle: "t", provider: .openAI, model: "gpt-4o", template: .general
            )
        }
        #expect(llm.summarizeCalls.count == 1)
    }

    @Test func otherSinglePassFailuresAreNotStaged() async {
        let llm = ScriptedLLMProvider { _, _ in throw AppError.apiError(statusCode: 400, message: "invalid model") }
        await #expect(throws: AppError.self) {
            _ = try await service(llm, budget: .forContextWindow(128_000, reservedOutputTokens: 8_192)).generate(
                transcriptText: twoHourTranscript, meetingTitle: "t", provider: .openAI, model: "gpt-4o", template: .general
            )
        }
        #expect(llm.summarizeCalls.count == 1)
    }

    // MARK: - Streamed progress

    @Test func streamedFragmentsReportARunningWordCount() async throws {
        let llm = ScriptedLLMProvider(summaryDeltas: [#"{"sections":[{"title":"Deci"#, #"sions","body":"we ship"}]}"#])
        let words = Recorded<Int>()
        _ = try await service(llm).generate(
            transcriptText: "[00:01] Ana: vamos", meetingTitle: "t", provider: .openAI, model: "m", template: .general,
            onTextProgress: { words.append($0) }
        )
        // Reset to 0 as the request starts; then sections, title, "Deci";
        // then "sions" continues that word, so only body, we, ship are new.
        #expect(words.values == [0, 3, 6])
    }

    @Test func eachStagedRequestRestartsTheWordCount() async throws {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice, summaryDeltas: ["two words"])
        let words = Recorded<Int>()
        _ = try await service(llm).generate(
            transcriptText: longTranscript(), meetingTitle: "Longa", provider: .appleOnDevice, model: "on-device",
            template: .general, onTextProgress: { words.append($0) }
        )
        let requests = llm.summarizeCalls.count
        #expect(requests > 2)
        #expect(words.values == Array(repeating: [0, 2], count: requests).flatMap { $0 })
    }

    @Test func contentDigestIsStableAndContentSensitive() {
        #expect(SummaryService.contentDigest("a") == SummaryService.contentDigest("a"))
        #expect(SummaryService.contentDigest("a") != SummaryService.contentDigest("b"))
        #expect(SummaryService.contentDigest("a").count == 64)
    }

    // MARK: - Title

    @Test func titleIsTheFirstSectionTitleFromAnExcerpt() async throws {
        let llm = ScriptedLLMProvider { _, _ in
            SummaryResult(sections: [SummarySection(title: "  Revisão do orçamento anual  ")])
        }
        let title = try await service(llm).generateTitle(
            transcriptText: String(repeating: "a", count: 5_000), provider: .openAI, model: "m"
        )
        #expect(title == "Revisão do orçamento anual")
        let prompt = try #require(llm.summarizeCalls.first?.userPrompt)
        #expect(prompt.count == "Transcript:\n".count + 2_000)
    }

    @Test func emptyTitleIsADecodingError() async {
        let llm = ScriptedLLMProvider { _, _ in SummaryResult(sections: [SummarySection(title: "   ")]) }
        await #expect(throws: AppError.self) {
            _ = try await service(llm).generateTitle(transcriptText: "texto", provider: .openAI, model: "m")
        }
        let none = ScriptedLLMProvider { _, _ in SummaryResult(sections: []) }
        await #expect(throws: AppError.self) {
            _ = try await service(none).generateTitle(transcriptText: "texto", provider: .openAI, model: "m")
        }
    }

    // MARK: - Translation

    private let sections = [
        SummarySection(title: "Decisions", items: ["ship it"]),
        SummarySection(title: "Next steps", body: "Review **budget**")
    ]

    @Test func translationKeepsTheSectionCount() async throws {
        let llm = ScriptedLLMProvider { _, _ in
            SummaryResult(sections: [SummarySection(title: "Decisões"), SummarySection(title: "Próximos passos")])
        }
        let result = try await service(llm).translate(
            sections: sections, to: .portuguese, provider: .openAI, model: "m"
        )
        #expect(result.sections.map(\.title) == ["Decisões", "Próximos passos"])
        let call = try #require(llm.summarizeCalls.first)
        #expect(call.systemPrompt.contains(MeetingLanguage.portuguese.displayName))
        #expect(call.userPrompt == "Summary:\n\(SummaryService.markdownText(from: sections))")
    }

    @Test func translationWithNoSectionsFails() async {
        let llm = ScriptedLLMProvider { _, _ in SummaryResult(sections: []) }
        do {
            _ = try await service(llm).translate(sections: sections, to: .spanish, provider: .openAI, model: "m")
            Issue.record("expected a failure")
        } catch let error as AppError {
            #expect(error.logCode == AppError.summaryTranslationFailed("").logCode)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func translationThatChangesTheSectionCountFails() async {
        let llm = ScriptedLLMProvider { _, _ in SummaryResult(sections: [SummarySection(title: "Uma só")]) }
        do {
            _ = try await service(llm).translate(sections: sections, to: .french, provider: .openAI, model: "m")
            Issue.record("expected a failure")
        } catch let error as AppError {
            #expect(error.logCode == AppError.summaryTranslationFailed("").logCode)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
