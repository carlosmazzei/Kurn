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
    /// Structured extraction needs an intact JSON document; prose may stop naturally.
    var requiresCompleteJSON = false

    /// The extraction's output budget follows the model's published output
    /// limit (`modelOutputLimit`, from the model catalog) up to a 32k cap, so
    /// a long meeting is not cut and re-split at a fixed 8k; the deadline grows
    /// with it (300 s per 8k-equivalent, at most 600 s). On-device keeps its clamp.
    static func knowledgeExtraction(for provider: AIProvider, modelOutputLimit: Int? = nil) -> Self {
        if provider.kind == .appleOnDevice {
            return Self(maxOutputTokens: FoundationModelsProvider.clampedOutputTokens(document.maxOutputTokens),
                        timeout: document.timeout, requiresCompleteJSON: true)
        }
        let output = modelOutputLimit.map { min(knowledgeExtractionOutputCap, $0) } ?? document.maxOutputTokens
        let timeout = min(600, document.timeout * max(1, Double(output) / Double(document.maxOutputTokens) / 2))
        return Self(maxOutputTokens: output, timeout: timeout, requiresCompleteJSON: true)
    }

    static let knowledgeExtractionOutputCap = 32_768

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

/// Collects the token usage providers report while a caller's task runs, so
/// a pipeline (knowledge extraction) can account for its calls without every
/// `chat` signature returning usage. Only vendor-reported counts are added.
final class TokenUsageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var prompt = 0
    private var completion = 0
    private var reported = false

    var total: TokenUsage? {
        lock.withLock { reported ? TokenUsage(promptTokens: prompt, completionTokens: completion) : nil }
    }

    func add(_ usage: TokenUsage) {
        lock.withLock { prompt += usage.promptTokens; completion += usage.completionTokens; reported = true }
    }
}

enum TokenUsageRecording {
    @TaskLocal static var sink: TokenUsageSink?

    /// Records the usage in a response body, in whichever vendor shape it uses:
    /// OpenAI/compatible `usage.prompt_tokens`/`completion_tokens` (also the
    /// Responses API after normalisation), Anthropic `usage.input_tokens`/
    /// `output_tokens`, Gemini `usageMetadata.promptTokenCount`/`candidatesTokenCount`.
    static func record(responseBody data: Data) {
        guard let sink, let usage = parse(data) else { return }
        sink.add(usage)
    }

    static func parse(_ data: Data) -> TokenUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let usage = root["usage"] as? [String: Any] {
            if let prompt = usage["prompt_tokens"] as? Int, let completion = usage["completion_tokens"] as? Int {
                return TokenUsage(promptTokens: prompt, completionTokens: completion)
            }
            if let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int {
                return TokenUsage(promptTokens: input, completionTokens: output)
            }
        }
        if let meta = root["usageMetadata"] as? [String: Any], let prompt = meta["promptTokenCount"] as? Int {
            return TokenUsage(promptTokens: prompt, completionTokens: meta["candidatesTokenCount"] as? Int ?? 0)
        }
        return nil
    }
}
