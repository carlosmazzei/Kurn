import Testing
@testable import AgentHarness

struct AgentCompactionPromptTests {
    @Test func hostProfileAppliesToInitialUpdatedAndSplitTurnSummaries() throws {
        let prompts = AgentCompactionPrompts(system: "Host summary system", historySummary: "Host initial instructions",
                                             updateSummary: "Host update instructions", turnPrefix: "Host prefix instructions")
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 10_000, summaryPrompts: prompts))
        let initial = AgentCompactionPlan(previousSummary: nil, messagesToSummarize: [.user("Earlier request")],
                                          turnPrefix: [], kept: [])
        let updated = AgentCompactionPlan(previousSummary: "Previous facts", messagesToSummarize: [.user("New facts")],
                                          turnPrefix: [.user("Turn prefix")], kept: [])
        let requests = try [#require(compactor.historySummaryRequest(for: initial)),
                            #require(compactor.historySummaryRequest(for: updated)),
                            #require(compactor.turnPrefixSummaryRequest(for: updated))]
        for (request, instructions) in zip(requests, [prompts.historySummary, prompts.updateSummary, prompts.turnPrefix]) {
            #expect(request.systemPrompt == prompts.system)
            guard case .user(let content)? = request.messages.first else { Issue.record("Missing summary input"); return }
            #expect(content.hasSuffix(instructions))
            #expect(request.tools.isEmpty)
        }
    }
}
