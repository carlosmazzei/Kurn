import Testing
@testable import Kurn

@MainActor
struct ChatProviderPolicyTests {
    @Test func scopeControlsMatchFactoryRoutingWithoutResolvingCredentials() {
        let supported: [AIProviderKind] = [.openAICompatible, .anthropic, .googleGemini]
        for kind in AIProviderKind.allCases {
            #expect(kind.supportsAgentChat == supported.contains(kind))
        }
    }

    @Test func legacySourcePreparationIsLazyForEveryAgentProvider() {
        var loads = 0
        for kind in AIProviderKind.allCases {
            let previous = loads
            let sources = ChatLegacySources.prepare(for: kind) {
                loads += 1
                return ChatLegacySources(transcriptText: "Legacy context")
            }
            #expect(loads == previous + (kind.supportsAgentChat ? 0 : 1))
            #expect(sources.transcriptText == (kind.supportsAgentChat ? nil : "Legacy context"))
            #expect(sources.candidates.isEmpty)
            #expect(sources.summariesByMeeting.isEmpty)
            #expect(sources.articlesByMeeting.isEmpty)
        }
    }
}
