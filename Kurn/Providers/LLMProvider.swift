//
//  LLMProvider.swift
//  Kurn
//
//  The two capabilities a vendor can offer, as two protocols:
//  `LLMProvider` generates text (summaries, chat, documents) and
//  `TranscriptionProvider` turns audio into a transcript. A vendor conforms to
//  what it actually serves — OpenAI-compatible endpoints to both, ElevenLabs
//  only to transcription, Anthropic, Gemini and the on-device model only to
//  text generation.
//
//  They used to be one protocol whose missing half every vendor stubbed with a
//  throw (ElevenLabs' `summarize`/`chat`, everyone else's inherited
//  `transcribe`), so passing the wrong vendor to a call site compiled and
//  failed at runtime. Now it does not compile. Implementations talk to their
//  HTTP APIs via URLSession and must be safe to call from any task
//  (`Sendable`).
//

import Foundation
import KurnCore

/// Structured summary returned by a chat/messages completion: the reply's
/// "## " sections (`SummaryMarkdown`), an ordered list whose titles the
/// template decides.
struct SummaryResult: Sendable {
    var sections: [SummarySection]
}

/// One turn in a chat conversation. `system` is passed separately to
/// `LLMProvider.chat`, so message lists normally hold only `user`/`assistant`.
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable, Codable { case system, user, assistant }
    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Request budget for free-form text generation. Interactive chat stays
/// responsive, while document generation gets the same room and timeout as a
/// full meeting summary.
struct TextGenerationOptions: Sendable, Equatable {
    let maxOutputTokens: Int
    let timeout: TimeInterval

    static let chat = Self(
        maxOutputTokens: LLMHTTP.chatMaxOutputTokens,
        timeout: LLMHTTP.chatTimeout
    )
    static let document = Self(
        maxOutputTokens: LLMHTTP.documentMaxOutputTokens,
        timeout: LLMHTTP.summaryTimeout
    )
}

/// Token counts a provider reported for one call, when the vendor's API
/// exposes them. Never estimated or inferred locally — only what the
/// provider itself returned in-band with the response, so a cost
/// estimate built on it (`ModelPricing`) inherits the same accuracy the
/// vendor's own billing does. `nil` at the call site (rather than this type)
/// is how "this vendor/response didn't report usage" is expressed.
struct TokenUsage: Sendable, Equatable, Codable {
    let promptTokens: Int
    let completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
}

/// A vendor's speech-to-text route, used by cloud (`.whisperAPI`)
/// transcription through `ProviderFactory.whisperProvider`.
protocol TranscriptionProvider: Sendable {
    /// Vendor this provider represents.
    var provider: AIProvider { get }

    /// Transcribe a single audio blob (one chunk). `language` is a hint; the
    /// returned `RawTranscript.language` reflects what the service detected.
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript
}

/// A vendor's text-generation route: summaries, chat and documents.
protocol LLMProvider: Sendable {
    /// Vendor this provider represents.
    var provider: AIProvider { get }

    /// Produce a structured meeting summary from a fully built prompt.
    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult

    /// Streaming variant of `summarize`: the same Markdown contract and the same
    /// result, but received incrementally so a long generation is bounded by
    /// silence rather than by a fixed total timeout, and so the caller can
    /// show that text is arriving. `onDelta` gets the raw generated text (the
    /// Markdown being written) as it arrives — progress, never content to
    /// display. A failure before the first fragment is retried like a
    /// buffered request; once text has arrived the call never retries. A
    /// conformer without a streaming route uses the extension default, which
    /// delivers nothing until `summarize` returns.
    func streamSummary(
        systemPrompt: String,
        userPrompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> SummaryResult

    /// Free-form multi-turn text completion. Unlike `summarize`, this returns
    /// plain text (no section contract); it backs transcript correction, topic
    /// analysis and auto-tagging. `messages` are the user/assistant turns in order.
    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String
}

extension LLMProvider {
    /// Default streaming summary: the buffered `summarize`, with no deltas.
    /// Correct for any conformer (the on-device model, test doubles), just
    /// not incremental.
    func streamSummary(
        systemPrompt: String,
        userPrompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> SummaryResult {
        try await summarize(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func chat(systemPrompt: String, messages: [ChatMessage]) async throws -> String {
        try await chat(systemPrompt: systemPrompt, messages: messages, options: .chat)
    }
}
