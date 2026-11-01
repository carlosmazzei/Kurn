public enum FluidAudioLiveModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case nemotronUnified

    public static let `default`: Self = .automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Parakeet EOU / Nemotron Multilingual"
        case .nemotronUnified: return "Nemotron Unified 0.6B"
        }
    }

    public var supportedLanguageCodes: Set<String> {
        switch self {
        case .automatic: return ["en", "es", "fr", "it", "pt", "de", "zh", "ja"]
        case .nemotronUnified: return FluidAudioASRModel.europeanLanguageCodes
        }
    }

    public var supportsAutoDetect: Bool { true }

    public func supports(_ language: MeetingLanguage) -> Bool {
        guard let code = language.whisperCode else { return supportsAutoDetect }
        return supportedLanguageCodes.contains(code)
    }
}
