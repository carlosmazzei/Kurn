//
//  AIProvider.swift
//  Kurn
//
//  A configured LLM vendor (`AIProvider`) and the API shape it speaks
//  (`AIProviderKind`). `isUsable` lives next to the on-device availability
//  check in `Providers/FoundationModelsProvider.swift`.
//

import Foundation
import KurnCore

/// API shape a configured LLM provider speaks.
enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic
    case googleGemini
    /// ElevenLabs' own API shape (`xi-api-key` auth, Scribe speech-to-text) —
    /// transcription-only, no chat/summarize route. See
    /// `AIProvider.supportsSummarization`.
    case elevenLabs
    /// Apple's on-device `FoundationModels` framework. Unlike the other kinds,
    /// this speaks no HTTP at all — no base URL, no API key — so it is excluded
    /// from `AddProviderView`'s type picker and never reaches `LLMHTTP`.
    case appleOnDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .googleGemini: return "Google Gemini"
        case .elevenLabs: return "ElevenLabs"
        case .appleOnDevice: return "On-Device"
        }
    }

    var defaultBaseURLString: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .elevenLabs: return "https://api.elevenlabs.io/v1"
        case .appleOnDevice: return ""
        }
    }

    /// Kinds a user can pick when adding or retyping a provider. `.appleOnDevice`
    /// speaks no HTTP and is seeded once as a built-in, never user-created, so it
    /// is excluded from `AddProviderView`/`ProviderEditor`'s type picker.
    static var networkCases: [AIProviderKind] { allCases.filter { $0 != .appleOnDevice } }
}

/// Configured LLM provider used for summaries. Built-ins are presets; users can
/// add more providers by choosing an API shape and a base URL.
struct AIProvider: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var kind: AIProviderKind
    var baseURLString: String
    var brandHex: String
    var defaultModel: String
    var isBuiltIn: Bool
    var legacyKeychainAccount: String?

    var rawValue: String { id }

    var keychainAccount: String {
        legacyKeychainAccount ?? "provider_\(id)_api_key"
    }

    /// Whether this provider can run cloud transcription. OpenAI-compatible
    /// vendors expose the `/audio/transcriptions` (Whisper) route — OpenAI, Groq,
    /// and any custom OpenAI-compatible endpoint. ElevenLabs exposes its own
    /// Scribe speech-to-text route. Anthropic/Gemini have no such route, so
    /// they're excluded from the transcription-provider picker.
    var supportsTranscription: Bool { kind == .openAICompatible || kind == .elevenLabs }

    /// Whether this provider can generate summaries/chat replies. Every kind
    /// except `.elevenLabs` (transcription-only) supports this — the inverse
    /// of `supportsTranscription` for Anthropic/Gemini, and true alongside it
    /// for OpenAI-compatible vendors.
    var supportsSummarization: Bool { kind != .elevenLabs }

    /// Whether this provider's transcription route can return native speaker
    /// diarization in the same response (e.g. ElevenLabs Scribe's `diarize`
    /// parameter). Keyed off `kind`, like the other capability flags, so a
    /// future provider of the same shape inherits this for free.
    ///
    /// This is the whole seam for adding a new native-diarization provider:
    /// flip this to `true` for its `kind`, and have its `TranscriptionProvider.transcribe`
    /// populate `RawTranscript.speakerTurns` however its API shapes that data
    /// (per-word speaker ids, per-segment labels, whatever it returns) — no
    /// other file needs to know the wire format. Everything downstream
    /// (`DiarizationEngine.transcriptionProviderNative`,
    /// `PipelineConfiguration.effectiveDiarization`, the Settings picker,
    /// `TranscriptionService.transcribeAndDiarize`) is already generic over
    /// "some provider said yes here", not over ElevenLabs specifically.
    ///
    /// Transcription and diarization otherwise remain fully independent
    /// axes — this flag only ever *adds* one extra diarization option
    /// (`.transcriptionProviderNative`) for a provider that raises it; it
    /// never restricts which of the three local diarizers
    /// (`.heuristic`/`.fluidAudio`/`.sherpaOnnx`) can be paired with any
    /// transcription engine or provider, including one that could diarize
    /// natively. Composing e.g. ElevenLabs for transcription with FluidAudio
    /// for diarization, or Apple Speech for transcription with sherpa-onnx
    /// for diarization, works with no special-casing anywhere, because the
    /// diarization stage never looks at which transcription engine/provider
    /// ran except to decide whether `.transcriptionProviderNative` applies.
    /// See `DiarizationSelectionTests`/`TranscriptionServicePipelineTests`
    /// for the tests that pin this down.
    var supportsNativeDiarization: Bool { kind == .elevenLabs }

    /// Default transcription model to request when the user hasn't picked
    /// one. Keyed off `kind` (not `id`) so a custom provider of the same kind
    /// gets the right default too. Groq's OpenAI-compatible audio route
    /// serves `whisper-large-v3` (not `whisper-1`); ElevenLabs serves
    /// `scribe_v1`.
    var defaultTranscriptionModel: String {
        if kind == .elevenLabs { return "scribe_v1" }
        return id == AIProvider.groq.id ? "whisper-large-v3" : "whisper-1"
    }

    /// Known-good models to fall back to when this provider's `/models`
    /// endpoint is unreachable (e.g. Groq's occasionally rejects an
    /// otherwise-valid key with a 403) or returns an empty list. Empty when no
    /// such fallback is known for this provider.
    var fallbackModels: [String] {
        if kind == .elevenLabs {
            // No /models-equivalent endpoint at all — this is the only model.
            return ["scribe_v1"]
        }
        if id == AIProvider.groq.id {
            return [
                "llama-3.3-70b-versatile",
                "llama-3.3-70b-specdec",
                "llama-3.1-8b-instant",
                "meta-llama/llama-4-scout-17b-16e-instruct",
                "meta-llama/llama-4-maverick-17b-128e-instruct",
                "gemma2-9b-it",
                "deepseek-r1-distill-llama-70b",
                "qwen/qwen3-32b",
                "whisper-large-v3",
                "whisper-large-v3-turbo"
            ].sorted()
        }
        if id == AIProvider.openAI.id {
            // OpenAI's /models response is dominated by chat models, so the
            // transcription picker's filter can be left with nothing to show
            // if the live fetch succeeds but returns none of these names
            // (or the endpoint is briefly unreachable) — keep the known-good
            // transcription models available regardless.
            return ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"].sorted()
        }
        return []
    }

    static let openAI = AIProvider(
        id: "openAI",
        displayName: "OpenAI",
        kind: .openAICompatible,
        baseURLString: "https://api.openai.com/v1",
        brandHex: "#10A37F",
        defaultModel: "gpt-5.4",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.openAI.rawValue
    )

    static let anthropic = AIProvider(
        id: "anthropic",
        displayName: "Anthropic",
        kind: .anthropic,
        baseURLString: "https://api.anthropic.com/v1",
        brandHex: "#D97757",
        defaultModel: "claude-3-5-sonnet-latest",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.anthropic.rawValue
    )

    static let google = AIProvider(
        id: "google",
        displayName: "Google AI",
        kind: .googleGemini,
        baseURLString: "https://generativelanguage.googleapis.com/v1beta",
        brandHex: "#4285F4",
        defaultModel: "gemini-1.5-pro",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.google.rawValue
    )

    static let groq = AIProvider(
        id: "groq",
        displayName: "Groq",
        kind: .openAICompatible,
        baseURLString: "https://api.groq.com/openai/v1",
        brandHex: "#F55036",
        defaultModel: "llama-3.3-70b-versatile",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.groq.rawValue
    )

    /// Transcription-only — no chat/summarize route, see
    /// `AIProviderKind.elevenLabs`. `defaultModel` is empty since it has no
    /// chat model to pick.
    static let elevenLabs = AIProvider(
        id: "elevenLabs",
        displayName: "ElevenLabs",
        kind: .elevenLabs,
        baseURLString: "https://api.elevenlabs.io/v1",
        brandHex: "#000000",
        defaultModel: "",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.elevenLabs.rawValue
    )

    /// The on-device provider: no base URL, no API key, and — unlike the other
    /// built-ins — exactly one model, so `defaultModel` is a fixed placeholder
    /// rather than something surfaced as a choice.
    static let appleOnDevice = AIProvider(
        id: "apple-on-device",
        displayName: "Apple On-Device",
        kind: .appleOnDevice,
        baseURLString: "",
        brandHex: "#000000",
        defaultModel: "on-device",
        isBuiltIn: true
    )

    static let defaultProviders: [AIProvider] = [.appleOnDevice, .openAI, .anthropic, .google, .groq, .elevenLabs]

    init(
        id: String,
        displayName: String,
        kind: AIProviderKind,
        baseURLString: String,
        brandHex: String = "#64748B",
        defaultModel: String = "",
        isBuiltIn: Bool = false,
        legacyKeychainAccount: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURLString = baseURLString
        self.brandHex = brandHex
        self.defaultModel = defaultModel
        self.isBuiltIn = isBuiltIn
        self.legacyKeychainAccount = legacyKeychainAccount
    }

    init?(rawValue: String) {
        if let provider = Self.defaultProviders.first(where: { $0.id == rawValue }) {
            self = provider
        } else {
            self = AIProvider(
                id: rawValue,
                displayName: rawValue,
                kind: .openAICompatible,
                baseURLString: AIProviderKind.openAICompatible.defaultBaseURLString
            )
        }
    }

    static func custom(displayName: String, kind: AIProviderKind, baseURLString: String) -> AIProvider {
        AIProvider(
            id: "custom-\(UUID().uuidString)",
            displayName: displayName,
            kind: kind,
            baseURLString: baseURLString
        )
    }
}
