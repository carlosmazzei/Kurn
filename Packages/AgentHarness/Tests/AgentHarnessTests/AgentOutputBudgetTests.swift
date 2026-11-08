import Testing
@testable import AgentHarness

struct AgentOutputBudgetTests {
    /// Independent expected values from pi's clamp-max-tokens tests (#10497), plus the device case.
    @Test(arguments: [
        [1_048_576, 220_815, 943_718, 794_638],
        [1_048_576, 10_000, 1_048_576, 1_034_480],
        [1_048_576, 100_000, 64_000, 64_000],
        [1_048_576, 912_000, 943_718, 32_768],
        [1_048_576, 1_030_000, 943_718, 14_480],
        [32_768, 20_000, 32_768, 8_672],
        [1_048_576, 1_050_000, 943_718, 1],
        [1_050_000, 54_879, 128_000, 128_000],
        [131_072, 80_000, 100_000, 39_072]
    ])
    func matchesPiHeadroomCases(values: [Int]) {
        var budget = AgentOutputBudget(requested: nil,
            policy: AgentContextPolicy(contextWindow: values[0], maxOutputTokens: values[2]))
        budget.fit(inputTokens: values[1])
        #expect(budget.tokens == values[3])
    }

    @Test func explicitCapsRemainCeilingsAndStillFitTheAvailableContext() {
        var budget = AgentOutputBudget(requested: 32_000, policy: AgentContextPolicy(contextWindow: 32_768, maxOutputTokens: 30_000))
        budget.fit(inputTokens: 20_000)
        #expect(budget.ceiling == 30_000)
        #expect(budget.tokens == 8_672)
        budget.fit(inputTokens: 0)
        #expect(budget.tokens == 28_672)
        var fallback = AgentOutputBudget(requested: nil, policy: AgentContextPolicy(contextWindow: 32_768))
        fallback.fit(inputTokens: 1_000)
        #expect(fallback.tokens == 4_096)
        #expect(fallback.isFallback)
    }

    @Test func safetyMarginAndItsRelaxationAreObservable() {
        var budget = AgentOutputBudget(requested: nil, policy: AgentContextPolicy(contextWindow: 1_050_000, maxOutputTokens: 128_000))
        budget.fit(inputTokens: 54_879)
        #expect(budget.diagnosticMetrics[.contextTokens] == 54_879)
        #expect(budget.diagnosticMetrics[.contextSafetyTokens] == 8_232)
        #expect(budget.diagnosticMetrics[.availableOutputTokens] == 986_889)
        #expect(budget.diagnosticMetrics[.contextSafetyRelaxed] == 0)
        budget.fit(inputTokens: 1_030_000)
        #expect(budget.tokens == 15_904)
        #expect(budget.diagnosticMetrics[.contextSafetyTokens] == 4_096)
        #expect(budget.diagnosticMetrics[.contextSafetyRelaxed] == 1)
    }

    @Test func adversarialCountsDoNotOverflow() {
        var budget = AgentOutputBudget(requested: -1, policy: AgentContextPolicy(contextWindow: 1))
        budget.fit(inputTokens: .max)
        #expect(budget.tokens == 1)
        budget.fit(inputTokens: -1)
        #expect(budget.inputTokens == 0)
        #expect(budget.tokens == 1)
    }

    @Test func everyRequestRecalculatesFromTheLatestUsageWithoutPrematureCompaction() async throws {
        let policy = AgentContextPolicy(contextWindow: 1_048_576, maxOutputTokens: 943_718)
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1")], usage: AgentUsage(inputTokens: 220_815)),
            AgentTurnResponse(text: "", toolCalls: [agentCall("2")], usage: AgentUsage(inputTokens: 912_000)),
            AgentTurnResponse(text: "", toolCalls: [agentCall("3")], usage: AgentUsage(inputTokens: 10_000)),
            AgentTurnResponse(text: "Done")
        ])
        var events: [AgentEvent] = []
        for try await event in NativeHarness(model: model, contextPolicy: policy)
            .run(systemPrompt: "System", history: [], prompt: "Question", tools: [agentTool()]) { events.append(event) }
        #expect(await model.requests.map(\.maxOutputTokens) == [943_718, 794_631, 32_768, 943_718])
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
        #expect(try agentOutcome(events).stopReason == .completed)
    }

    @Test func summariesUseTheModelCapacityInsteadOfFractionsOfTheReserve() throws {
        let policy = AgentContextPolicy(contextWindow: 1_050_000, reserveTokens: 100, maxOutputTokens: 128_000)
        let compactor = AgentContextCompactor(policy: policy)
        let plan = AgentCompactionPlan(previousSummary: nil, messagesToSummarize: [.user("Earlier facts")],
                                       turnPrefix: [.user("Turn prefix")], kept: [])
        #expect(compactor.historySummaryRequest(for: plan)?.maxOutputTokens == 128_000)
        #expect(compactor.turnPrefixSummaryRequest(for: plan)?.maxOutputTokens == 128_000)
        let crowded = AgentCompactionPlan(previousSummary: nil,
            messagesToSummarize: [.user(String(repeating: "a", count: 160_000))], turnPrefix: [], kept: [])
        let smaller = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 200_000, maxOutputTokens: 128_000),
                                            tokenEstimator: { $0.count })
        let request = try #require(smaller.historySummaryRequest(for: crowded))
        #expect(request.maxOutputTokens < 40_000)
        #expect(request.maxOutputTokens > 1)
        #expect(request.fittedHistoryOmittedCharacters == 0)
        #expect(request.contextOmittedCharacters == 0)
    }

    @Test func wireMinimumAdjustmentsRemainVisibleForSummariesAndNormalRequests() async throws {
        struct Model: AgentModel {
            let base = ScriptedAgentModel([AgentTurnResponse(text: "Checkpoint"), AgentTurnResponse(text: "Answer")])
            func streamTurn(_ request: AgentTurnRequest,
                            onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.outputBudgetAdjusted(requested: request.maxOutputTokens, sent: 16))
                return try await base.streamTurn(request, onEvent: onEvent)
            }
        }
        let policy = AgentContextPolicy(contextWindow: 1_000, reserveTokens: 0, keepRecentTokens: 100, maxOutputTokens: 128_000)
        let history: [AgentMessage] = [.user(tokens(700)), .assistant(text: tokens(400), toolCalls: [])]
        var facts: [AgentDiagnostic] = []
        for try await event in NativeHarness(model: Model(), contextPolicy: policy)
            .run(systemPrompt: "System", history: history, prompt: "Question", tools: []) {
            if case .diagnostic(let value) = event { facts.append(value) }
        }
        let adjustments = facts.filter { $0.kind == .outputBudgetAdjusted }
        #expect(adjustments.count == 2)
        #expect(adjustments.allSatisfy { $0.metrics[.maxOutputTokens] == 1 && $0.metrics[.sentMaxOutputTokens] == 16 })
    }
}
