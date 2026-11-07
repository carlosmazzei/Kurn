extension AIProviderKind {
    var supportsAgentChat: Bool {
        switch self {
        case .openAICompatible, .anthropic, .googleGemini: true
        case .appleOnDevice, .elevenLabs: false
        }
    }
}
