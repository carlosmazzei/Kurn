//
//  LLMProvider.swift
//  Kurn
//
//  Abstraction over the cloud vendors. Transcription is only meaningful for
//  vendors that expose a speech endpoint (OpenAI Whisper); summary generation is
//  supported by both. Implementations talk to their HTTP APIs via URLSession and
//  must be safe to call from any task (`Sendable`).
//

import Foundation
import KurnCore

/// Structured summary returned by a chat/messages completion. The shape is
/// template-driven, so it is just an ordered list of titled sections.
struct SummaryResult: Sendable {
    var sections: [SummarySection]
}

/// One turn in a chat conversation. `system` is passed separately to
/// `LLMProvider.chat`, so message lists normally hold only `user`/`assistant`.
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant }
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

/// Token counts a provider reported for one `streamChat` call, when the
/// vendor's API exposes them. Never estimated or inferred locally — only
/// what the provider itself returned in-band with the response, so a cost
/// estimate built on it (`ModelPricing`) inherits the same accuracy the
/// vendor's own billing does. `nil` at the call site (rather than this type)
/// is how "this vendor/response didn't report usage" is expressed.
struct TokenUsage: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
}

protocol LLMProvider: Sendable {
    /// Vendor this provider represents.
    var provider: AIProvider { get }

    /// Transcribe a single audio blob (one chunk). `language` is a hint; the
    /// returned `RawTranscript.language` reflects what the service detected.
    /// Vendors without speech support throw `AppError.transcriptionFailed`.
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript

    /// Produce a structured meeting summary from a fully built prompt.
    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult

    /// Free-form multi-turn chat completion. Unlike `summarize`, this returns
    /// plain text (no JSON-section contract), so it backs the "chat with your
    /// meetings" feature. `systemPrompt` carries the grounding instructions;
    /// `messages` are the user/assistant turns in order.
    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String

    /// Streaming variant of `chat`: calls `onDelta` once per text fragment as
    /// it arrives, in order, so the concatenation of every `onDelta` call is
    /// the same string `chat` would have returned. Deliberately shaped as a
    /// single `async throws` call with a callback — like `chat`, not an
    /// `AsyncSequence` — so it composes with `LLMHTTP`'s bounded transport
    /// (`ProviderHTTPTransport.swift`) the same way every other request does:
    /// one `withTaskCancellationHandler` call that cancels the in-flight
    /// request the instant the caller's task is cancelled, with no separate
    /// producer task whose lifetime could outlive it. `onDelta` may be called
    /// from a background executor; the receiver hops to the main actor
    /// itself. A conformer with no true streaming transport falls back to the
    /// `LLMProvider` extension's default below, which just delivers the whole
    /// `chat` reply as one fragment — still correct, just not incremental.
    /// Returns the token usage the vendor reported for this call, when its
    /// streaming response exposed one — `nil` for a vendor/response that
    /// didn't. This is the only place `streamChat` reports anything beyond
    /// text: never estimated locally, only relayed from the provider.
    @discardableResult
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> TokenUsage?
}

extension LLMProvider {
    /// Default for vendors with no speech endpoint wired here.
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("error.provider_no_transcribe", comment: "Provider has no transcription")
        )
    }

    func chat(systemPrompt: String, messages: [ChatMessage]) async throws -> String {
        try await chat(systemPrompt: systemPrompt, messages: messages, options: .chat)
    }

    @discardableResult
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> TokenUsage? {
        try await streamChat(systemPrompt: systemPrompt, messages: messages, options: .chat, onDelta: onDelta)
    }

    /// Default streaming implementation: awaits the whole `chat` reply and
    /// delivers it as one fragment. Correct for any conformer (including test
    /// doubles that only implement `chat`), just not incremental — and `chat`
    /// exposes no usage, so this always reports `nil` rather than guessing.
    @discardableResult
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> TokenUsage? {
        let text = try await chat(systemPrompt: systemPrompt, messages: messages, options: options)
        onDelta(text)
        return nil
    }
}
