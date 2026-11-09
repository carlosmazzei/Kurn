import Testing
@testable import AgentHarness

struct ModelContextWindowsTests {
    @Test func longestPrefixWins() {
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4o-2024-08-06") == 128_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4-0613") == 8_192)
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4.1-mini") == 1_047_576)
        #expect(ModelContextWindows.knownWindow(forModel: "gemini-1.5-pro-002") == 2_000_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gemini-2.5-flash") == 1_048_576)
        #expect(ModelContextWindows.knownWindow(forModel: "o1-mini") == 128_000)
    }

    @Test func vendorPrefixedIdsMatchOnTheirLastComponent() {
        #expect(ModelContextWindows.knownWindow(forModel: "models/gemini-2.0-flash") == 1_000_000)
        #expect(ModelContextWindows.knownWindow(forModel: "anthropic/claude-sonnet-4-5") == 200_000)
        #expect(ModelContextWindows.knownWindow(forModel: "openai/gpt-oss-120b") == 131_072)
    }

    @Test func matchingIgnoresCase() {
        #expect(ModelContextWindows.knownWindow(forModel: "Claude-Opus-4") == 200_000)
    }

    @Test func unknownOrEmptyNamesHaveNoWindow() {
        #expect(ModelContextWindows.knownWindow(forModel: "my-local-model") == nil)
        #expect(ModelContextWindows.knownWindow(forModel: "") == nil)
        #expect(ModelContextWindows.knownWindow(forModel: "vendor/") == nil)
    }

    @Test func agentWindowPrefersReportedThenTableThenUnknown() {
        #expect(ModelContextWindows.agentWindow(reported: 1_048_576, model: "gpt-4o") == 1_048_576)
        #expect(ModelContextWindows.agentWindow(reported: 0, model: "gpt-4o") == 128_000)
        #expect(ModelContextWindows.agentWindow(reported: nil, model: "claude-sonnet-4-5") == 200_000)
        #expect(ModelContextWindows.agentWindow(reported: nil, model: "custom-local") == ModelContextWindows.unknownWindow)
    }

}
