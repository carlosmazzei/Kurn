//
//  Enums.swift
//  Kurn
//
//  Shared value types used across models, services, and views.
//

import Foundation
import SwiftData

/// Lifecycle of a recording's transcription.
enum TranscriptionStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case inProgress
    /// Interrupted mid-transcription (app backgrounded, killed, or cancelled by
    /// the system) with a checkpoint saved; resumes automatically on the next
    /// foreground pass.
    case pending
    case done
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return NSLocalizedString("status.none", comment: "No transcript")
        case .inProgress:
            return NSLocalizedString("status.in_progress", comment: "In progress")
        case .pending:
            return NSLocalizedString("status.pending", comment: "Queued to resume")
        case .done:
            return NSLocalizedString("status.done", comment: "Done")
        case .failed:
            return NSLocalizedString("status.failed", comment: "Failed")
        }
    }
}

/// Fine-grained stage within an in-progress transcription, surfaced to the UI so
/// the user can see what the app is currently doing (e.g. cleaning audio vs.
/// transcribing). Reported by `TranscriptionService` as it advances.
enum TranscriptionPhase: Sendable, Equatable {
    case preparing
    case preprocessing
    /// Detecting the spoken language (only the FluidAudio LID engine reports this;
    /// engines that detect the language themselves skip it).
    case detectingLanguage
    /// Running voice-activity detection to find speech regions.
    case detectingSpeech
    /// Active transcription. `progress` is a fraction in `0...1` when the engine
    /// can report it (e.g. the chunked Whisper path), or `nil` when the stage is
    /// indeterminate (e.g. a single on-device pass). `chunks` carries the current
    /// chunk number and total for long recordings so the UI can show both a bar
    /// and a "chunk X of Y" label.
    case transcribing(progress: Double?, chunks: ChunkProgress? = nil)
    case finalizing

    /// Short, user-facing description of the current stage.
    var displayName: String {
        switch self {
        case .preparing: return NSLocalizedString("phase.preparing", comment: "Preparing")
        case .preprocessing: return NSLocalizedString("phase.preprocessing", comment: "Cleaning audio")
        case .detectingLanguage: return NSLocalizedString("phase.detecting_language", comment: "Detecting language")
        case .detectingSpeech: return NSLocalizedString("phase.detecting_speech", comment: "Detecting speech")
        case .transcribing(let progress, let chunks):
            guard let progress else {
                return NSLocalizedString("phase.transcribing", comment: "Transcribing")
            }
            let percent = Int((progress * 100).rounded())
            if let chunks {
                return String(
                    format: NSLocalizedString("phase.transcribing_chunk_progress", comment: "Transcribing with percent and chunk count"),
                    percent, chunks.completed, chunks.total
                )
            }
            return String(
                format: NSLocalizedString("phase.transcribing_progress", comment: "Transcribing with percent"),
                percent
            )
        case .finalizing: return NSLocalizedString("phase.finalizing", comment: "Finalizing")
        }
    }

    /// Overall completion in `0...1` for a single, always-determinate progress
    /// bar. Each stage occupies a fixed band so the bar only ever moves forward —
    /// the indeterminate linear bar rendered as a dead, empty line, leaving the
    /// user with no feedback during the stages between cleaning and transcribing.
    /// Within transcribing, the engine's real sub-progress fills that band.
    var fractionComplete: Double {
        switch self {
        case .preparing: return 0.05
        case .preprocessing: return 0.15
        case .detectingLanguage: return 0.22
        case .detectingSpeech: return 0.28
        case .transcribing(let progress, _): return 0.30 + 0.62 * min(1, max(0, progress ?? 0))
        case .finalizing: return 0.95
        }
    }
}

/// Chunk counter surfaced in the transcription progress UI.
///
/// `completed` is the chunk currently being shown to the user: it is the index
/// of the chunk in flight (1-based), not the count of fully finished chunks.
/// For example, when the first of three chunks is being uploaded, the UI shows
/// "chunk 1 of 3" even though zero chunks have finished. Once the first chunk
/// completes, the display advances to "chunk 2 of 3" while the next chunk is
/// processed. `total` is the total number of chunks in the plan.
struct ChunkProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
}

/// Microphone pickup pattern preference for the built-in mic.
enum MicPickup: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Omnidirectional: capture the whole room / all participants.
    case wholeRoom
    /// Cardioid (directional): favour the person in front of the device.
    case focusSpeaker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeRoom: return NSLocalizedString("micpickup.whole_room", comment: "Whole room")
        case .focusSpeaker: return NSLocalizedString("micpickup.focus_speaker", comment: "Focus on speaker")
        }
    }
}

/// How the meetings list is sorted. Date and title are stable database sorts;
/// duration is computed from related recordings so it is applied in memory.
enum MeetingsSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case dateNewest
    case dateOldest
    case titleAZ
    case durationLongest
    case durationShortest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateNewest: return NSLocalizedString("meetings.sort.date_newest", comment: "Newest first")
        case .dateOldest: return NSLocalizedString("meetings.sort.date_oldest", comment: "Oldest first")
        case .titleAZ: return NSLocalizedString("meetings.sort.title_az", comment: "Title A–Z")
        case .durationLongest: return NSLocalizedString("meetings.sort.duration_longest", comment: "Longest first")
        case .durationShortest: return NSLocalizedString("meetings.sort.duration_shortest", comment: "Shortest first")
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest, .dateOldest: return "calendar"
        case .titleAZ: return "textformat"
        case .durationLongest, .durationShortest: return "clock"
        }
    }

    /// Apply the chosen ordering to a list of meetings. The default
    /// `.dateNewest` is a no-op because `@Query` already sorts by `createdAt`
    /// descending; the other cases re-sort in memory (necessary for the
    /// computed `totalDuration`).
    func apply(to meetings: [Meeting]) -> [Meeting] {
        switch self {
        case .dateNewest:
            return meetings
        case .dateOldest:
            return meetings.sorted { $0.createdAt < $1.createdAt }
        case .titleAZ:
            return meetings.sorted {
                let lhs = $0.title.localizedCaseInsensitiveCompare($1.title)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.createdAt > $1.createdAt
            }
        case .durationLongest:
            return meetings.sorted {
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
                return $0.createdAt > $1.createdAt
            }
        case .durationShortest:
            return meetings.sorted {
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration < $1.totalDuration }
                return $0.createdAt > $1.createdAt
            }
        }
    }
}

/// Top-level library bucket selecting which meetings the list shows. Combines
/// with date filters and search; cannot itself be saved per-meeting. `.all` is
/// the inbox-style default and hides archived meetings; users see archived
/// meetings only when explicitly selecting `.archive`.
enum MeetingsLibraryBucket: String, Codable, Sendable, CaseIterable, Identifiable {
    case all
    case inbox
    case favorites
    case archive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return NSLocalizedString("meetings.bucket.all", comment: "All meetings")
        case .inbox: return NSLocalizedString("meetings.bucket.inbox", comment: "Inbox")
        case .favorites: return NSLocalizedString("meetings.bucket.favorites", comment: "Favorites")
        case .archive: return NSLocalizedString("meetings.bucket.archive", comment: "Archive")
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .inbox: return "tray"
        case .favorites: return "star.fill"
        case .archive: return "archivebox"
        }
    }

    /// Whether `meeting` belongs in this bucket given its current state.
    /// `.all` hides archived meetings; `.inbox` is meetings without a folder
    /// (also non-archived); `.favorites` is starred non-archived meetings;
    /// `.archive` is the only bucket that shows archived meetings.
    func contains(_ meeting: Meeting) -> Bool {
        switch self {
        case .all: return !meeting.isArchived
        case .inbox: return meeting.folder == nil && !meeting.isArchived
        case .favorites: return meeting.isFavorite && !meeting.isArchived
        case .archive: return meeting.isArchived
        }
    }
}

/// What the meetings list is currently showing: either a built-in bucket
/// (All / Favorites / Archive) or a user folder identified by its persistent
/// model id. Wrapped in one type so `MeetingsListView` keeps a single
/// `selection` state and one filter codepath for both. Archived meetings are
/// never visible from a folder selection — they stay in `Archive` until the
/// user restores them.
enum LibrarySelection: Hashable, Sendable {
    case bucket(MeetingsLibraryBucket)
    case folder(PersistentIdentifier)
    case smartFolder(UUID)

    static let allMeetings: LibrarySelection = .bucket(.all)
    static let inbox: LibrarySelection = .bucket(.inbox)

    /// Whether `meeting` matches this selection. `Inbox` (the synthetic bucket
    /// for meetings without a folder) and per-folder views both exclude
    /// archived meetings; `Archive` and `Favorites` work as on PR 2a.
    /// Smart folders apply their saved predicate.
    func contains(_ meeting: Meeting, smartFolderFilter: MeetingFilter? = nil) -> Bool {
        switch self {
        case .bucket(let bucket):
            return bucket.contains(meeting)
        case .folder(let id):
            guard !meeting.isArchived else { return false }
            return meeting.folder?.persistentModelID == id
        case .smartFolder:
            return smartFolderFilter?.matches(meeting) ?? false
        }
    }
}

/// Recording audio quality, mapped to the encoder bit rate.
enum AudioQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case high
    case standard
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return NSLocalizedString("quality.high", comment: "High")
        case .standard: return NSLocalizedString("quality.standard", comment: "Standard")
        case .low: return NSLocalizedString("quality.low", comment: "Low")
        }
    }

    /// AAC bit rate (bits per second) for the recorder.
    var bitRate: Int {
        switch self {
        case .high: return 128_000
        case .standard: return 64_000
        case .low: return 32_000
        }
    }
}

/// Where a transcript is produced.
enum TranscriptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case onDevice
    case whisperAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return NSLocalizedString("mode.on_device", comment: "On-device")
        case .whisperAPI: return NSLocalizedString("mode.whisper", comment: "Whisper API")
        }
    }
}

/// Speaker diarization engine used when transcribing a recording.
enum DiarizationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Pitch/ZCR/spectral-tilt clustering, always available, no downloads.
    case heuristic
    /// FluidAudio's on-device diarization models (downloaded on first use).
    case fluidAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heuristic: return NSLocalizedString("diarization.heuristic", comment: "Heuristic")
        case .fluidAudio: return NSLocalizedString("diarization.fluid_audio", comment: "FluidAudio")
        }
    }

    /// FluidAudio model family that must be downloaded before this engine runs,
    /// or `nil` when it needs no download.
    var requiredModelSet: ModelSet? {
        switch self {
        case .heuristic: return nil
        case .fluidAudio: return .diarization
        }
    }
}

/// Transcription engine used to turn audio into text. Replaces the older
/// `TranscriptionMode` + "multilingual on-device" boolean pair with a single
/// explicit choice. `TranscriptionMode` is still persisted on `Recording` for
/// back-compat; map via `storageMode`.
enum TranscriptionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple `SFSpeechRecognizer`, on-device, fixed locale (no language detection).
    case appleSpeech
    /// FluidAudio multilingual on-device batch ASR (Parakeet TDT v3), detects
    /// the spoken language from the audio. Requires a model download.
    case fluidAudioParakeet
    /// OpenAI Whisper cloud API (chunked upload). Requires an OpenAI API key.
    case whisperAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return NSLocalizedString("transcription.apple_speech", comment: "Apple Speech")
        case .fluidAudioParakeet: return NSLocalizedString("transcription.fluid_parakeet", comment: "FluidAudio multilingual")
        case .whisperAPI: return NSLocalizedString("transcription.whisper", comment: "Whisper API")
        }
    }

    /// FluidAudio model family that must be downloaded before this engine runs,
    /// or `nil` when it needs no download.
    var requiredModelSet: ModelSet? {
        switch self {
        case .appleSpeech, .whisperAPI: return nil
        case .fluidAudioParakeet: return .onDeviceASR
        }
    }

    /// The legacy `TranscriptionMode` to persist on `Recording` so the stored
    /// field stays valid without a SwiftData migration.
    var storageMode: TranscriptionMode {
        switch self {
        case .appleSpeech, .fluidAudioParakeet: return .onDevice
        case .whisperAPI: return .whisperAPI
        }
    }
}

/// Offline DSP cleanup engine applied before the transcription path.
enum PreprocessingEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Speech-tuned filter chain (high-pass, presence EQ, AGC/limiter, mono 16 kHz).
    case standardDSP
    /// No cleanup — feed the original recording straight to the engines.
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standardDSP: return NSLocalizedString("preprocessing.standard", comment: "Standard cleanup")
        case .none: return NSLocalizedString("preprocessing.none", comment: "No cleanup")
        }
    }
}

/// Voice-activity detection engine used to find speech regions.
enum VADEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Energy-threshold (dBFS) detection over 100 ms frames. Always available.
    case energyThreshold
    /// FluidAudio's Silero VAD CoreML model. Requires a model download.
    case fluidAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .energyThreshold: return NSLocalizedString("vad.energy", comment: "Energy threshold")
        case .fluidAudio: return NSLocalizedString("vad.fluid_audio", comment: "FluidAudio (Silero)")
        }
    }

    var requiredModelSet: ModelSet? {
        switch self {
        case .energyThreshold: return nil
        case .fluidAudio: return .vad
        }
    }
}

/// Language-detection engine run before transcription to refine the language.
enum LanguageDetectionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Defer to the transcription engine's own detection (current behavior).
    case byTranscriber
    /// FluidAudio Parakeet detects the language, then pins the locale so even
    /// `appleSpeech` benefits from auto-detection. Requires a model download.
    case fluidAudioLID

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .byTranscriber: return NSLocalizedString("langdetect.by_transcriber", comment: "By transcriber")
        case .fluidAudioLID: return NSLocalizedString("langdetect.fluid_lid", comment: "FluidAudio detection")
        }
    }

    var requiredModelSet: ModelSet? {
        switch self {
        case .byTranscriber: return nil
        case .fluidAudioLID: return .onDeviceASR
        }
    }
}

/// API shape a configured LLM provider speaks.
enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic
    case googleGemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .googleGemini: return "Google Gemini"
        }
    }

    var defaultBaseURLString: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }
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

    static let defaultProviders: [AIProvider] = [.openAI, .anthropic, .google, .groq]

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

/// One speaker-attributed span of speech. Stored inside `Transcript` as JSON
/// `Data` because SwiftData does not persist arbitrary `Codable` arrays of
/// structs directly.
struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var speakerLabel: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Float?

    var duration: TimeInterval { max(0, endTime - startTime) }
}

/// Supported transcription languages, with the BCP-47 locale used for both the
/// on-device recognizer and Whisper hints. `autoDetect` lets the engine decide.
enum MeetingLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case autoDetect
    case portuguese
    case english
    case spanish
    case french
    case german
    case japanese
    case chinese

    var id: String { rawValue }

    /// BCP-47 identifier, or `nil` for auto-detect.
    var localeIdentifier: String? {
        switch self {
        case .autoDetect: return nil
        case .portuguese: return "pt-BR"
        case .english: return "en-US"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .japanese: return "ja-JP"
        case .chinese: return "zh-CN"
        }
    }

    /// Two-letter code Whisper expects in its `language` field, or `nil`.
    var whisperCode: String? {
        guard let id = localeIdentifier else { return nil }
        return String(id.prefix(2))
    }

    /// Map a two-letter language code (e.g. from a language detector) to a
    /// supported `MeetingLanguage`, or `.autoDetect` when it isn't one we pin.
    init(detectedCode code: String) {
        switch code.lowercased().prefix(2) {
        case "pt": self = .portuguese
        case "en": self = .english
        case "es": self = .spanish
        case "fr": self = .french
        case "de": self = .german
        case "ja": self = .japanese
        case "zh": self = .chinese
        default: self = .autoDetect
        }
    }

    var displayName: String {
        switch self {
        case .autoDetect: return NSLocalizedString("lang.auto", comment: "Auto-detect")
        case .portuguese: return NSLocalizedString("lang.pt", comment: "Portuguese")
        case .english: return NSLocalizedString("lang.en", comment: "English")
        case .spanish: return NSLocalizedString("lang.es", comment: "Spanish")
        case .french: return NSLocalizedString("lang.fr", comment: "French")
        case .german: return NSLocalizedString("lang.de", comment: "German")
        case .japanese: return NSLocalizedString("lang.ja", comment: "Japanese")
        case .chinese: return NSLocalizedString("lang.zh", comment: "Chinese")
        }
    }
}
