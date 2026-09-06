//
//  MeetingChatSynthesisConcurrencyTests.swift
//  KurnTests
//
//  MeetingChatService.condenseBlocksConcurrently runs the library-wide
//  chat's map stage concurrently instead of one block at a time. The one
//  way a naive parallelization could get this wrong is silently, not by
//  crashing: mixing up which result belongs to which block once they
//  complete out of submission order. These tests script deliberately
//  inverted delays (the first block finishes last) to prove the result
//  stays ordered by block index, not completion order.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

/// Replies to a map-stage `chat` call by finding which scripted block
/// content the prompt embeds, waiting that block's configured delay, then
/// returning a marker naming it — so a test can tell which block a given
/// result came from regardless of completion order. Any prompt that doesn't
/// embed a known block (an "unrecognized" one, used to script a failure)
/// throws.
private final class ScriptedMapLLM: LLMProvider, @unchecked Sendable {
    let provider: AIProvider = .openAI
    private let delays: [String: Duration]

    init(delays: [String: Duration]) {
        self.delays = delays
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        throw AppError.transcriptionFailed("not scripted")
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        let content = messages.last?.content ?? ""
        guard let match = delays.first(where: { content.contains($0.key) }) else {
            throw AppError.transcriptionFailed("unrecognized block")
        }
        try await Task.sleep(for: match.value)
        return "NOTES(\(match.key))"
    }
}

/// Thread-safe collector for the `ChatEventHandler` closure, which may be
/// invoked from a background executor.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatStreamEvent] = []

    func handler(_ event: ChatStreamEvent) {
        lock.withLock { events.append(event) }
    }

    var recorded: [ChatStreamEvent] { lock.withLock { events } }
}

struct MeetingChatSynthesisConcurrencyTests {

    @Test func resultsStayOrderedByBlockIndexRegardlessOfCompletionOrder() async throws {
        // Block A is submitted first but configured to finish LAST, so a
        // completion-order bug (as opposed to an index-order one) would
        // surface here as "NOTES(BLOCK_A)" landing in the wrong slot.
        let blocks = ["BLOCK_A", "BLOCK_B", "BLOCK_C"]
        let llm = ScriptedMapLLM(delays: [
            "BLOCK_A": .milliseconds(60),
            "BLOCK_B": .milliseconds(5),
            "BLOCK_C": .milliseconds(30)
        ])

        let results = try await MeetingChatService.condenseBlocksConcurrently(
            question: "What changed?", blocks: blocks, llm: llm,
            onEvent: { _ in }, runID: OperationID()
        )

        #expect(results == ["NOTES(BLOCK_A)", "NOTES(BLOCK_B)", "NOTES(BLOCK_C)"])
    }

    @Test func reportsOneProgressEventPerBlockEndingAtTheFullCount() async throws {
        let blocks = ["BLOCK_A", "BLOCK_B", "BLOCK_C"]
        let llm = ScriptedMapLLM(delays: [
            "BLOCK_A": .milliseconds(1), "BLOCK_B": .milliseconds(1), "BLOCK_C": .milliseconds(1)
        ])
        let recorder = EventRecorder()

        _ = try await MeetingChatService.condenseBlocksConcurrently(
            question: "q", blocks: blocks, llm: llm,
            onEvent: { recorder.handler($0) }, runID: OperationID()
        )

        let fractions: [String] = recorder.recorded.compactMap {
            if case .progress(let text) = $0 { return text }
            return nil
        }
        // Three completions, however interleaved, each bump the count by
        // exactly one — the fractions must end at "3/3" regardless of order.
        let expectedFinal = String(format: NSLocalizedString("chat.phase.progress_fraction", comment: ""), 3, 3)
        #expect(fractions.count == 3)
        #expect(fractions.last == expectedFinal)
    }

    @Test func singleBlockReportsNoProgressEvent() async throws {
        let llm = ScriptedMapLLM(delays: ["ONLY_BLOCK": .milliseconds(1)])
        let recorder = EventRecorder()

        let results = try await MeetingChatService.condenseBlocksConcurrently(
            question: "q", blocks: ["ONLY_BLOCK"], llm: llm,
            onEvent: { recorder.handler($0) }, runID: OperationID()
        )

        #expect(results == ["NOTES(ONLY_BLOCK)"])
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aFailingBlockThrowsAndReportsAFailedReliabilityEventAtItsOwnStage() async {
        // "BAD_BLOCK" isn't in `delays`, so ScriptedMapLLM throws for it.
        let llm = ScriptedMapLLM(delays: ["GOOD_BLOCK": .milliseconds(1)])
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()

        await #expect(throws: AppError.self) {
            _ = try await MeetingChatService.condenseBlocksConcurrently(
                question: "q", blocks: ["GOOD_BLOCK", "BAD_BLOCK"], llm: llm,
                onEvent: { _ in }, runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.contains { $0.outcome == .failed && $0.stage == "map_2_of_2" })
    }
}
