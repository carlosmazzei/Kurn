//
//  LLMTranscriptCorrectorLoopTests.swift
//  KurnTests
//
//  `LLMTranscriptCorrector.correct` end to end over a scripted provider: the
//  eligible segments are batched, each reply is applied by id, progress
//  reaches the end, and every way the stage can come up short — nothing to
//  send, no provider, a failed or unparseable batch — is reported as its own
//  outcome rather than as a clean pass.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct LLMTranscriptCorrectorLoopTests {

    private struct ProviderDown: Error {}

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.withLock { values.append(value) } }
        var all: [Double] { lock.withLock { values } }
    }

    private static func segment(_ text: String, confidence: Float? = nil, at start: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: "Speaker 1", startTime: start, endTime: start + 2, text: text, confidence: confidence)
    }

    private static func reply(_ corrections: [(UUID, String)]) -> String {
        let items = corrections.map { #"{"id":"\#($0.0.uuidString)","text":"\#($0.1)"}"# }
        return #"{"segments":["# + items.joined(separator: ",") + "]}"
    }

    private static func correct(
        _ segments: [TranscriptSegment],
        with llm: ScriptedLLMProvider?,
        progress: ProgressLog = ProgressLog()
    ) async -> TranscriptCorrectionResult {
        let corrector = LLMTranscriptCorrector(resolveProvider: { _, _ in
            guard let llm else { throw AppError.noAPIKey(provider: "OpenAI") }
            return llm
        })
        return await corrector.correct(
            segments: segments, language: .english, provider: .openAI, model: "gpt-4o",
            onProgress: { progress.append($0) }
        )
    }

    @Test func eligibleSegmentsAreCorrectedByIdAndConfidentOnesAreNotSent() async {
        let uncertain = Self.segment("we ned to ship this fetur", confidence: 0.3)
        let confident = Self.segment("already right", confidence: 0.99, at: 2)
        let reply = Self.reply([(uncertain.id, "we need to ship this feature")])
        let llm = ScriptedLLMProvider(chat: { _, _ in reply })
        let progress = ProgressLog()

        let result = await Self.correct([uncertain, confident], with: llm, progress: progress)

        #expect(result.outcome == .succeeded)
        #expect(result.segments.map(\.text) == ["we need to ship this feature", "already right"])
        #expect(llm.chatCalls.count == 1)
        let sent = llm.chatCalls.first?.messages.first?.content ?? ""
        #expect(sent.contains(uncertain.id.uuidString))
        #expect(!sent.contains(confident.id.uuidString))
        #expect(llm.chatCalls.first?.systemPrompt == LLMTranscriptCorrector.systemPrompt(language: .english))
        #expect(progress.all.last == 1)
    }

    @Test func nothingEligibleIsSkippedWithoutResolvingAProvider() async {
        let result = await Self.correct([Self.segment("confident", confidence: 0.99), Self.segment("  ")], with: nil)
        #expect(result.outcome == .skipped)
        #expect(result.reason == .noInput)
    }

    @Test func noUsableProviderDegradesAndKeepsTheText() async {
        let segments = [Self.segment("we ned it")]
        let result = await Self.correct(segments, with: nil)
        #expect(result.outcome == .degraded)
        #expect(result.reason == .providerUnavailable)
        #expect(result.segments.map(\.text) == ["we ned it"])
    }

    @Test func everyBatchFailingIsAFailedStage() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in throw ProviderDown() })
        let result = await Self.correct([Self.segment("we ned it")], with: llm)
        #expect(result.outcome == .failed)
        #expect(result.reason == .engineFailed)
        #expect(result.segments.map(\.text) == ["we ned it"])
    }

    @Test func anUnparseableReplyCountsAsAFailedBatch() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in "I fixed everything for you!" })
        let result = await Self.correct([Self.segment("we ned it")], with: llm)
        #expect(result.outcome == .failed)
    }

    @Test func someBatchesFailingDegradesTheStage() async {
        let segments = (0..<(LLMTranscriptCorrector.maxSegmentsPerBatch + 1)).map {
            Self.segment("segment \($0)", at: TimeInterval($0) * 2)
        }
        let llm = ScriptedLLMProvider(chat: { _, index in
            if index == 0 { throw ProviderDown() }
            return #"{"segments":[]}"#
        })
        let progress = ProgressLog()

        let result = await Self.correct(segments, with: llm, progress: progress)

        #expect(llm.chatCalls.count == 2)
        #expect(result.outcome == .degraded)
        #expect(result.reason == .engineFailed)
        #expect(result.segments.count == segments.count)
        #expect(progress.all.count == 2)
        #expect(progress.all.last == 1)
    }
}
