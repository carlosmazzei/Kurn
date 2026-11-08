import Foundation
import KurnCore

extension AIProviderKind {
    /// Whether this provider kind can run the agent chat. Chat and documents need a cloud text
    /// provider; Apple's on-device model and transcription-only vendors cannot.
    var supportsAgentChat: Bool {
        switch self {
        case .openAICompatible, .anthropic, .googleGemini: true
        case .appleOnDevice, .elevenLabs: false
        }
    }
}
