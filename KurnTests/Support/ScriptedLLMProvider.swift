//
//  ScriptedLLMProvider.swift
//  KurnTests
//
//  An `LLMProvider` whose replies are closures, recording every prompt it is
//  sent, so a service's prompt building and its handling of each kind of
//  reply can be exercised with no key, network or on-device model.
//

import Foundation
@testable import Kurn

final class ScriptedLLMProvider: LLMProvider, @unchecked Sendable {
    struct SummarizeCall: Equatable {
        var systemPrompt: String
        var userPrompt: String
    }

    struct ChatCall: Equatable {
        var systemPrompt: String
        var messages: [ChatMessage]
        var options: TextGenerationOptions
    }

    let provider: AIProvider

    private let lock = NSLock()
    private var _summarizeCalls: [SummarizeCall] = []
    private var _chatCalls: [ChatCall] = []
    private let summarizeReply: @Sendable (SummarizeCall, Int) throws -> SummaryResult
    private let chatReply: @Sendable (ChatCall, Int) throws -> String

    init(
        provider: AIProvider = .openAI,
        summarize: @escaping @Sendable (SummarizeCall, Int) throws -> SummaryResult = { _, _ in
            SummaryResult(sections: [SummarySection(title: "Notes", body: "scripted")])
        },
        chat: @escaping @Sendable (ChatCall, Int) throws -> String = { _, _ in "scripted reply" }
    ) {
        self.provider = provider
        self.summarizeReply = summarize
        self.chatReply = chat
    }

    var summarizeCalls: [SummarizeCall] { lock.withLock { _summarizeCalls } }
    var chatCalls: [ChatCall] { lock.withLock { _chatCalls } }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        let call = SummarizeCall(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let index = lock.withLock { () -> Int in
            _summarizeCalls.append(call)
            return _summarizeCalls.count - 1
        }
        return try summarizeReply(call, index)
    }

    func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
        let call = ChatCall(systemPrompt: systemPrompt, messages: messages, options: options)
        let index = lock.withLock { () -> Int in
            _chatCalls.append(call)
            return _chatCalls.count - 1
        }
        return try chatReply(call, index)
    }
}

/// Values appended from `@Sendable` callbacks, read after the call returns.
final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    var values: [Value] { lock.withLock { _values } }
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
}
