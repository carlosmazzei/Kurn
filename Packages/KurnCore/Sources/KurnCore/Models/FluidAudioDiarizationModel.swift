public enum FluidAudioDiarizationModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case pyannote
    case nemotron3

    public static let `default`: Self = .pyannote

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pyannote: return "Pyannote"
        case .nemotron3: return "Nemotron 3"
        }
    }

    public var supportsPinnedSpeakerCount: Bool { self == .pyannote }

    public var maximumSpeakers: Int? { self == .nemotron3 ? 8 : nil }

    public var approximateBytes: Int64 {
        switch self {
        case .pyannote: return 100_000_000
        case .nemotron3: return 190_000_000
        }
    }

    public var folderName: String {
        switch self {
        case .pyannote: return "speaker-diarization"
        case .nemotron3: return "nemotron-3-diarization"
        }
    }
}
