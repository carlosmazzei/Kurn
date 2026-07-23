//
//  QuestionRouterTests.swift
//  KurnTests
//
//  The lookup-vs-synthesis routing for the library-wide "Ask": the multilingual
//  keyword heuristic, global-aggregate detection, and the LLM tie-break's
//  synthesis-by-default behaviour.
//

import Foundation
import Testing
@testable import Kurn

/// Minimal stubbed provider: `chat` returns a fixed reply (or throws), enough to
/// drive `QuestionRouter.classify`'s tie-break.
private struct StubLLM: LLMProvider {
    var provider: AIProvider = .openAI
    var reply: String?
    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        SummaryResult(sections: [])
    }
    func chat(systemPrompt: String, messages: [ChatMessage]) async throws -> String {
        guard let reply else { throw AppError.apiError(statusCode: 0, message: "stub") }
        return reply
    }
}

struct QuestionRouterTests {

    @Test func heuristicClassifiesSynthesisAcrossLanguages() {
        let synthesis = [
            "How many meetings discussed hiring?",   // en
            "Quantas reuniões falaram de orçamento?", // pt
            "¿Cuántas reuniones trataron el tema?",  // es
            "Combien de réunions ont abordé cela ?", // fr
            "Quante riunioni ne hanno parlato?",     // it
            "Wie viele Meetings behandelten das?",   // de
            "所有会议里有多少提到预算？"                  // zh
        ]
        for question in synthesis {
            #expect(QuestionRouter.heuristic(question) == .synthesis, "\(question)")
        }
    }

    @Test func heuristicClassifiesLookup() {
        #expect(QuestionRouter.heuristic("Who said the deadline was Friday?") == .lookup)
        #expect(QuestionRouter.heuristic("Quem disse que o prazo é sexta?") == .lookup)
    }

    @Test func heuristicReturnsNilWhenAmbiguous() {
        #expect(QuestionRouter.heuristic("Tell me about the project") == nil)
    }

    @Test func globalAggregateDetection() {
        #expect(QuestionRouter.isGlobalAggregate("How many meetings mention risk?"))
        #expect(QuestionRouter.isGlobalAggregate("Liste todas as decisões"))
        #expect(!QuestionRouter.isGlobalAggregate("What did Ana say?"))
    }

    @Test func classifyUsesHeuristicWithoutCallingLLM() async {
        // Clear synthesis marker → no LLM needed; a throwing stub must not matter.
        let route = await QuestionRouter.classify("How many meetings?", llm: StubLLM(reply: nil))
        #expect(route == .synthesis)
    }

    @Test func classifyBreaksTieWithLLM() async {
        let ambiguous = "Tell me about the project"
        #expect(await QuestionRouter.classify(ambiguous, llm: StubLLM(reply: "LOOKUP")) == .lookup)
        #expect(await QuestionRouter.classify(ambiguous, llm: StubLLM(reply: "SYNTHESIS")) == .synthesis)
    }

    @Test func classifyDefaultsToSynthesisOnFailure() async {
        // Heuristic nil + LLM throws → default synthesis (never lose an aggregate).
        let route = await QuestionRouter.classify("Tell me about the project", llm: StubLLM(reply: nil))
        #expect(route == .synthesis)
    }
}
