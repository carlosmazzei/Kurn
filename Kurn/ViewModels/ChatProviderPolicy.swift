import Foundation
import KurnCore

extension AIProviderKind {
    var supportsAgentChat: Bool {
        switch self {
        case .openAICompatible, .anthropic, .googleGemini: true
        case .appleOnDevice, .elevenLabs: false
        }
    }
}

struct ChatLegacySources {
    var transcriptText: String?
    var candidates: [SemanticSearchService.Candidate] = []
    var summariesByMeeting: [UUID: String] = [:]
    var articlesByMeeting: [UUID: WikiArticleSnapshot] = [:]

    @MainActor
    static func prepare(for kind: AIProviderKind, load: () -> Self) -> Self {
        kind.supportsAgentChat ? Self() : load()
    }
}
