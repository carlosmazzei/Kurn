import Testing
@testable import Kurn

struct ContextBudgetTests {
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

}
