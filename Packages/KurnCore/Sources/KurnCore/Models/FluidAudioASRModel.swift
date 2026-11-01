public enum FluidAudioASRModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case parakeetV3
    case nemotronUnified
    case bark3
    case bark3Clean
    case phonon2
    case nemotronTranscribeLite

    public static let `default`: Self = .parakeetV3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet TDT v3"
        case .nemotronUnified: return "Nemotron Unified 0.6B"
        case .bark3: return "Bark 3.0"
        case .bark3Clean: return "Bark 3.0 Clean"
        case .phonon2: return "Phonon-2"
        case .nemotronTranscribeLite: return "Nemotron 3.5 Transcribe Lite"
        }
    }

    public var approximateBytes: Int64 {
        switch self {
        case .parakeetV3: return 480_000_000
        case .nemotronUnified: return 1_200_000_000
        case .bark3: return 435_000_000
        case .bark3Clean: return 445_000_000
        case .phonon2: return 360_000_000
        case .nemotronTranscribeLite: return 1_400_000_000
        }
    }

    public var folderName: String {
        switch self {
        case .parakeetV3: return "parakeet-tdt-0.6b-v3"
        case .nemotronUnified: return "nemotron-labs-unified-asr"
        case .bark3: return "bark-3.0"
        case .bark3Clean: return "bark-3.0-clean"
        case .phonon2: return "phonon-2"
        case .nemotronTranscribeLite: return "nemotron-3.5-transcribe-lite"
        }
    }

    public var supportedLanguageCodes: Set<String> {
        supportsAutoDetect ? Self.europeanLanguageCodes : ["en"]
    }

    public var supportsAutoDetect: Bool {
        self == .parakeetV3 || self == .nemotronUnified
    }

    public var checkpointProviderID: String? {
        self == .parakeetV3 ? nil : "fluidaudio:\(rawValue)"
    }

    public func supports(_ language: MeetingLanguage) -> Bool {
        guard let code = language.whisperCode else { return supportsAutoDetect }
        return supportedLanguageCodes.contains(code)
    }

    static let europeanLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "cs", "sk", "hu", "ro",
        "bg", "hr", "sl", "da", "sv", "fi", "et", "lv", "lt", "el", "mt", "ru", "uk"
    ]
}
