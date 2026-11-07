import Testing
@testable import Kurn

struct ChatProviderPolicyTests {
    @Test func scopeControlsMatchFactoryRoutingWithoutResolvingCredentials() {
        let supported: [AIProviderKind] = [.openAICompatible, .anthropic, .googleGemini]
        for kind in AIProviderKind.allCases {
            #expect(kind.supportsAgentChat == supported.contains(kind))
        }
    }
}
