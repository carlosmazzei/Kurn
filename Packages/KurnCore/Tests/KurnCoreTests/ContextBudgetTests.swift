//
//  ContextBudgetTests.swift
//  KurnCoreTests
//
//  Per-model request budgets: token estimation per script, the window →
//  budget arithmetic, the known-model table and the provider error that
//  sends a request back to the staged path.
//

import Foundation
import Testing
@testable import KurnCore

struct ContextBudgetTests {

    // MARK: - Token estimate

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

    // MARK: - Budget

    @Test func fitsComparesTheEstimateAgainstTheInputAllowance() {
        let budget = ContextBudget(inputTokens: 10, mapBlockTokens: 5)
        #expect(budget.fits(String(repeating: "a", count: 35)))
        #expect(!budget.fits(String(repeating: "a", count: 36)))
        #expect(!budget.fits(String(repeating: "中", count: 11)))
    }

    @Test func mapBlockCharsFollowTheTextsOwnScript() {
        let budget = ContextBudget(inputTokens: 2_000, mapBlockTokens: 1_000)
        #expect(budget.mapBlockChars(for: String(repeating: "a", count: 100)) == 3_500)
        #expect(budget.mapBlockChars(for: String(repeating: "中", count: 100)) == 1_000)
    }

    @Test func mapBlockNeverExceedsTheSinglePassAllowance() {
        let budget = ContextBudget(inputTokens: 100, mapBlockTokens: 500)
        #expect(budget.mapBlockTokens == 100)
    }

    @Test func aLargeWindowIsCappedAtThePracticalLimit() {
        let budget = ContextBudget.forContextWindow(1_000_000, reservedOutputTokens: 8_192)
        #expect(budget.inputTokens == ContextBudget.practicalCapTokens)
        #expect(budget.mapBlockTokens == ContextBudget.practicalCapTokens * 3 / 4)
    }

    @Test func aMidSizeWindowReservesOutputOverheadAndSafetyMargin() {
        let budget = ContextBudget.forContextWindow(128_000, reservedOutputTokens: 8_192)
        #expect(budget.inputTokens == 102_400 - 8_192 - ContextBudget.promptOverheadTokens)
    }

    @Test func aWindowSmallerThanTheOutputReservationKeepsAPositiveFloor() {
        let budget = ContextBudget.forContextWindow(8_192, reservedOutputTokens: 8_192)
        #expect(budget.inputTokens == ContextBudget.minimumInputTokens)
    }

    @Test func aTypicalModernWindowFitsATwoHourMeetingInOnePass() {
        // ~100k characters of Latin-script transcript, the size the old fixed
        // 80k-character threshold always sent through the staged path.
        let twoHours = String(repeating: "[12:34] Speaker 1: we agreed to ship it\n", count: 2_500)
        #expect(!ContextBudget.conservative.fits(twoHours))
        #expect(ContextBudget.forContextWindow(128_000, reservedOutputTokens: 8_192).fits(twoHours))
    }

    @Test func conservativeAndOnDeviceKeepThePreviousCharacterThresholdsForLatinText() {
        let latin = String(repeating: "a", count: 10)
        #expect(ContextBudget.conservative.mapBlockChars(for: latin) == 59_500)
        #expect(ContextBudget.onDevice.mapBlockChars(for: latin) == 4_900)
        #expect(ContextBudget.conservative.fits(String(repeating: "a", count: 80_000)))
        #expect(ContextBudget.onDevice.fits(String(repeating: "a", count: 5_950)))
        #expect(!ContextBudget.onDevice.fits(String(repeating: "a", count: 6_000)))
    }

    // MARK: - Known windows

    @Test func longestPrefixWins() {
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4o-2024-08-06") == 128_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4-0613") == 8_192)
        #expect(ModelContextWindows.knownWindow(forModel: "gpt-4.1-mini") == 1_000_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gemini-1.5-pro-002") == 2_000_000)
        #expect(ModelContextWindows.knownWindow(forModel: "gemini-2.5-flash") == 1_000_000)
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

    // MARK: - Context overflow

    @Test func vendorOverflowMessagesAreRecognised() {
        let messages = [
            "This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.",
            "prompt is too long: 210000 tokens > 200000 maximum",
            "The input token count (1100000) exceeds the maximum number of tokens allowed (1048576).",
            "Please reduce the length of the messages or completion."
        ]
        for message in messages {
            #expect(AppError.apiError(statusCode: 400, message: message).isContextOverflow)
        }
        #expect(AppError.apiError(statusCode: 422, message: "context_length_exceeded").isContextOverflow)
    }

    @Test func payloadTooLargeIsAlwaysOverflow() {
        #expect(AppError.apiError(statusCode: 413, message: "Request too large for model").isContextOverflow)
    }

    @Test func otherFailuresAreNotOverflow() {
        #expect(!AppError.apiError(statusCode: 400, message: "invalid model").isContextOverflow)
        #expect(!AppError.apiError(statusCode: 500, message: "context length").isContextOverflow)
        #expect(!AppError.apiError(statusCode: 429, message: "rate limited").isContextOverflow)
        #expect(!AppError.summaryTruncated.isContextOverflow)
    }
}
