import AgentHarness
import Foundation
import Testing
@testable import Kurn

/// The composer's model chip: the context gauge and the model/reasoning picker.
@MainActor
struct ChatModelChoiceTests {
    private func contextStep(window: Int) -> AgentRunStep {
        var step = AgentRunStep(kind: .context, status: .finished)
        step.contextResolution = AgentContextResolution(contextWindowTokens: window, source: .fixedFallback, reason: .unknownModel)
        return step
    }

    @Test func theGaugeNeedsBothTheUsageAndTheWindow() throws {
        #expect(ChatContextGauge(usedTokens: nil, steps: [[contextStep(window: 1_000)]]) == nil)
        #expect(ChatContextGauge(usedTokens: 10, steps: [[AgentRunStep(kind: .turn, status: .finished)]]) == nil)
        // The newest run's window wins.
        let gauge = try #require(ChatContextGauge(usedTokens: 125_000,
                                                  steps: [[contextStep(window: 200_000)], [], [contextStep(window: 1_050_000)]]))
        #expect(gauge.windowTokens == 1_050_000 && gauge.percent == 12)
        #expect(gauge.text.hasPrefix("12% · 125k / 1"))
        let full = try #require(ChatContextGauge(usedTokens: 300_000, steps: [[contextStep(window: 200_000)]]))
        #expect(full.fraction == 1 && full.percent == 100)
        let localize: (String) -> String = { _ in "%d%% of %@" }
        #expect(full.accessibilityText(localize: localize) == "100% of 200k")
    }

    @Test func tokenCountsAreCompact() {
        #expect(ChatContextGauge.compact(950) == "950")
        #expect(ChatContextGauge.compact(125_000) == "125k")
        #expect(ChatContextGauge.compact(1_000).hasSuffix("k"))
        #expect(ChatContextGauge.compact(1_050_000).hasSuffix("M"))
    }

    @Test func theModelListKeepsTheChoiceAndFallsBack() async {
        #expect(ChatModelPickerViewModel.options(loaded: ["a", "b"], current: "c", fallback: []) == ["c", "a", "b"])
        #expect(ChatModelPickerViewModel.options(loaded: ["a", "a", ""], current: "a", fallback: []) == ["a"])
        #expect(ChatModelPickerViewModel.options(loaded: [], current: "x", fallback: ["y"]) == ["x", "y"])

        let listed = ChatModelPickerViewModel(provider: .openAI, current: "gpt-5.4", load: { _ in ["gpt-5.4", "gpt-5.4-mini"] })
        await listed.refresh(current: "gpt-5.4")
        #expect(listed.models == ["gpt-5.4", "gpt-5.4-mini"] && !listed.loadFailed && !listed.isLoading)

        struct Failure: Error {}
        let failing = ChatModelPickerViewModel(provider: .openAI, current: "custom", load: { _ in throw Failure() })
        await failing.refresh(current: "custom")
        #expect(failing.loadFailed && failing.models.first == "custom")
        #expect(failing.models.count == Set(failing.models).count)
    }

    @Test func theChipNamesTheLevelOnlyWhenItIsSent() {
        let localize: (String) -> String = { $0 == "chat.reasoning.high" ? "High" : $0 }
        #expect(ChatModelPickerViewModel.chipText(model: "gpt", level: .high, offered: true, localize: localize) == "gpt · High")
        #expect(ChatModelPickerViewModel.chipText(model: "gpt", level: .high, offered: false, localize: localize) == "gpt")
        #expect(ChatModelPickerViewModel.chipText(model: "gpt", level: nil, offered: true, localize: localize) == "gpt")
        let picker = ChatModelPickerViewModel(provider: .openAI, current: "gpt-5.4", load: { _ in [] })
        #expect(picker.offersReasoning(model: "gpt-5.4") && !picker.offersReasoning(model: "gpt-4.1-mini"))
    }
}
