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
}
