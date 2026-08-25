//
//  FoundationModelsProvider.swift
//  Kurn
//
//  On-device implementation of `LLMProvider` backed by Apple's `FoundationModels`
//  framework (`SystemLanguageModel` / `LanguageModelSession`). Unlike every other
//  provider here, this one makes no network request at all: a summary or chat
//  reply is generated entirely on-device, closing the gap where a user with no
//  cloud API key got transcription and nothing else. See F1 in
//  `docs/roadmap.md`.
//

import Foundation
import FoundationModels

/// Whether the on-device model can actually be used right now, shared by
/// `ProviderFactory` (to fail a request the same way a missing API key fails)
/// and the Settings provider list (to show the same reason inline, without
/// either place duplicating the reason strings).
enum OnDeviceModelAvailability {
    /// `nil` when the model is available; otherwise a localized, user-facing
    /// reason it currently isn't.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return NSLocalizedString(
                "settings.on_device_reason_ineligible",
                comment: "This device does not support Apple Intelligence"
            )
        case .unavailable(.appleIntelligenceNotEnabled):
            return NSLocalizedString(
                "settings.on_device_reason_not_enabled",
                comment: "Apple Intelligence is not turned on"
            )
        case .unavailable(.modelNotReady):
            return NSLocalizedString(
                "settings.on_device_reason_not_ready",
                comment: "The on-device model is not ready yet"
            )
        // Covers any future reason the framework adds; a specific case above
        // always wins when it matches.
        default:
            return NSLocalizedString(
                "settings.on_device_reason_unknown",
                comment: "The on-device model is unavailable for an unknown reason"
            )
        }
    }
}

extension AIProvider {
    /// Whether this provider is usable right now for a summary/chat call: a
    /// Keychain key for a cloud vendor, or a runnable `SystemLanguageModel` for
    /// the on-device provider, which has no key at all. Every call site that
    /// used to gate on "does this provider have a key" (title generation, wiki
    /// generation, the correction/wiki toggles) should read this instead, so
    /// the on-device provider isn't treated as permanently unconfigured.
    var isUsable: Bool {
        kind == .appleOnDevice
            ? OnDeviceModelAvailability.unavailableReason == nil
            : KeychainManager.shared.hasValue(for: keychainAccount)
    }
}

struct FoundationModelsProvider: LLMProvider {
    let provider: AIProvider

    init(provider: AIProvider = .appleOnDevice) {
        self.provider = provider
    }

    // transcribe: not overridden. FoundationModels has no speech endpoint, so
    // the `LLMProvider` extension's default throws `AppError.transcriptionFailed`,
    // same as AnthropicProvider/GoogleProvider.

    // MARK: - Summary (guided generation)

    /// Mirrors `SummaryJSON`'s shape so a generated result can reuse
    /// `SummaryJSON.summarySections`'s trimming/filtering instead of duplicating
    /// it. Guided generation means there is no free-text JSON to parse here —
    /// `SummaryJSON.parse`'s fence-stripping and `AppError.summaryTruncated`
    /// are both unreachable on this path. Not `private`: the `@Generable`
    /// macro emits a conformance extension that can't see a private type.
    @Generable
    struct GeneratedSummary: Sendable {
        @Generable
        struct Section: Sendable {
            let title: String
            let body: String?
            let items: [String]?
        }
        let sections: [Section]
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        let session = LanguageModelSession(instructions: systemPrompt)
        let options = GenerationOptions(maximumResponseTokens: Self.clampedOutputTokens(LLMHTTP.summaryMaxOutputTokens))
        // Extract `.content` inside the task rather than returning the whole
        // `Response`, which doesn't conform to `Sendable` and can't cross the
        // `withTimeout` task-group boundary as-is.
        let generated = try await Self.withTimeout(seconds: LLMHTTP.summaryTimeout) {
            try await session.respond(to: userPrompt, generating: GeneratedSummary.self, options: options).content
        }
        let asSummaryJSON = SummaryJSON(sections: generated.sections.map {
            SummaryJSON.Section(title: $0.title, body: $0.body, items: $0.items)
        })
        return SummaryResult(sections: asSummaryJSON.summarySections)
    }

    // MARK: - Chat (plain text)

    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String {
        let session = LanguageModelSession(instructions: systemPrompt)
        let prompt = Self.foldPrompt(messages)
        let genOptions = GenerationOptions(maximumResponseTokens: Self.clampedOutputTokens(options.maxOutputTokens))
        let generated = try await Self.withTimeout(seconds: options.timeout) {
            try await session.respond(to: prompt, options: genOptions).content
        }
        let content = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AppError.decodingError("empty on-device response")
        }
        return content
    }

    // MARK: - Helpers

    /// The on-device session window is shared across instructions, input, and
    /// output (~4096 tokens total as of iOS 26) — `LLMHTTP`'s cloud output
    /// budgets (4096–8192 tokens) would alone exceed it. This is a conservative
    /// first-cut ceiling, not a measured figure; tune against real on-device
    /// runs alongside `SummaryService`'s on-device char thresholds.
    private static let maxOnDeviceOutputTokens = 1_024

    // Not `private`: unit-tested directly.
    static func clampedOutputTokens(_ requested: Int) -> Int {
        min(requested, maxOnDeviceOutputTokens)
    }

    /// `LanguageModelSession` takes one prompt per turn, not an OpenAI-shaped
    /// role array, so the history is folded into a single prompt — the same
    /// approach `GoogleProvider` already uses for Gemini's turns. Any `.system`
    /// entry is dropped: the system prompt is passed separately as the
    /// session's `instructions`. Not `private`: unit-tested directly, since a
    /// live `LanguageModelSession` response can't be asserted on in CI.
    static func foldPrompt(_ messages: [ChatMessage]) -> String {
        messages
            .filter { $0.role != .system }
            .map { "\($0.role == .assistant ? "Assistant" : "User"): \($0.content)" }
            .joined(separator: "\n\n")
    }

    /// A local model call has nothing transient to retry, but it can still run
    /// long on an overloaded device — bound it the same way `FluidAudioDiarizer`
    /// bounds its own on-device processing.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppError.apiError(
                    statusCode: 0,
                    message: NSLocalizedString("error.on_device_generation_timeout", comment: "On-device generation timed out")
                )
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
