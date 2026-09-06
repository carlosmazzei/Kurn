//
//  MeetingChatStreamingTests.swift
//  KurnTests
//
//  `MeetingChatService.streamAnswer` is the single choke point every chat
//  reply's generation flows through: it announces the `.answering` phase,
//  forwards `LLMProvider.streamChat`'s deltas as `ChatStreamEvent`s, and
//  reports the "answer"-stage `ReliabilityEvent` on cancellation/failure that
//  `MeetingChatSynthesis`'s map stage mirrors. These tests drive it directly
//  against a scripted `LLMProvider`, with no network involved — the
//  provider-level SSE transport is covered separately in
//  `ProviderHTTPTests.swift`.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

/// A minimal `LLMProvider` whose `streamChat` plays back a scripted sequence
/// of deltas, or fails, or reports cancellation — never touching the network.
private final class ScriptedStreamingLLM: LLMProvider, @unchecked Sendable {
    let provider: AIProvider = .openAI
    private let deltas: [String]
    private let failure: Error?
    private let cancels: Bool
    private let usage: TokenUsage?

    init(deltas: [String] = [], failure: Error? = nil, cancels: Bool = false, usage: TokenUsage? = nil) {
        self.deltas = deltas
        self.failure = failure
        self.cancels = cancels
        self.usage = usage
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        throw AppError.transcriptionFailed("not scripted")
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        throw AppError.transcriptionFailed("not scripted")
    }

    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> TokenUsage? {
        if cancels { throw CancellationError() }
        if let failure { throw failure }
        for delta in deltas { onDelta(delta) }
        return usage
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

struct MeetingChatStreamingTests {

    @Test func forwardsAnsweringPhaseThenEachDeltaInOrder() async throws {
        let recorder = EventRecorder()
        let llm = ScriptedStreamingLLM(deltas: ["Hello", ", ", "world."])
        let service = MeetingChatService()

        let result = try await service.streamAnswer(
            systemPrompt: "sys",
            messages: [ChatMessage(role: .user, content: "hi")],
            llm: llm,
            onEvent: { recorder.handler($0) },
            runID: OperationID()
        )

        #expect(result.text == "Hello, world.")
        #expect(result.usage == nil)
        let events = recorder.recorded
        guard case .phase(.answering) = events.first else {
            Issue.record("expected the first event to be .phase(.answering), got \(events)")
            return
        }
        let deltas: [String] = events.dropFirst().compactMap {
            if case .delta(let text) = $0 { return text }
            return nil
        }
        #expect(deltas == ["Hello", ", ", "world."])
    }

    @Test func forwardsTheProviderReportedUsage() async throws {
        let llm = ScriptedStreamingLLM(
            deltas: ["An answer."],
            usage: TokenUsage(promptTokens: 120, completionTokens: 40)
        )
        let service = MeetingChatService()

        let result = try await service.streamAnswer(
            systemPrompt: "sys",
            messages: [ChatMessage(role: .user, content: "hi")],
            llm: llm,
            onEvent: { _ in },
            runID: OperationID()
        )

        #expect(result.usage == TokenUsage(promptTokens: 120, completionTokens: 40))
        #expect(result.usage?.totalTokens == 160)
    }

    @Test func failureReportsOneFailedAnswerStageEvent() async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()
        let scriptedError = AppError.apiError(statusCode: 500, message: "boom")
        let llm = ScriptedStreamingLLM(failure: scriptedError)
        let service = MeetingChatService()

        await #expect(throws: AppError.self) {
            _ = try await service.streamAnswer(
                systemPrompt: "sys",
                messages: [ChatMessage(role: .user, content: "hi")],
                llm: llm,
                onEvent: { _ in },
                runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.count == 1)
        #expect(events.first?.outcome == .failed)
        #expect(events.first?.stage == "answer")
        #expect(events.first?.code == scriptedError.logCode)
    }

    @Test func cancellationReportsOneCancelledAnswerStageEvent() async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()
        let llm = ScriptedStreamingLLM(cancels: true)
        let service = MeetingChatService()

        await #expect(throws: CancellationError.self) {
            _ = try await service.streamAnswer(
                systemPrompt: "sys",
                messages: [ChatMessage(role: .user, content: "hi")],
                llm: llm,
                onEvent: { _ in },
                runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.count == 1)
        #expect(events.first?.outcome == .cancelled)
        #expect(events.first?.stage == "answer")
    }
}
