import Testing
@testable import AgentHarness

struct TokenEstimateTests {
    @Test func latinTextIsEstimatedAtThreeAndAHalfCharactersPerToken() {
        let text = String(repeating: "a", count: 3_500)
        #expect(TokenEstimate.tokens(in: text) == 1_000)
    }

    @Test func ideographicTextCostsOneTokenPerCharacter() {
        let text = String(repeating: "会议", count: 500)
        #expect(TokenEstimate.tokens(in: text) == 1_000)
        #expect(TokenEstimate.charactersPerToken(in: text) == 1.0)
    }

    @Test func hangulAndKanaCountAsIdeographic() {
        #expect(TokenEstimate.tokens(in: "회의") == 2)
        #expect(TokenEstimate.tokens(in: "かいぎ") == 3)
    }

    @Test func otherScriptsSitBetweenLatinAndIdeographic() {
        let text = String(repeating: "م", count: 1_000)
        #expect(TokenEstimate.tokens(in: text) == 500)
    }

    @Test func mixedTextAddsEachScriptsShare() {
        let text = String(repeating: "a", count: 350) + String(repeating: "中", count: 100)
        #expect(TokenEstimate.tokens(in: text) == 200)
    }

    @Test func emptyTextIsZeroTokensWithTheLatinRatio() {
        #expect(TokenEstimate.tokens(in: "") == 0)
        #expect(TokenEstimate.charactersPerToken(in: "") == 3.5)
    }

    @Test func partialTokensRoundUp() {
        #expect(TokenEstimate.tokens(in: "ab") == 1)
    }

}
