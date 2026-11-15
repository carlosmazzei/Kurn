import AgentHarness
import Foundation
import Testing
import KurnCore
@testable import Kurn

struct ChatContextTraceTests {
    @Test func genericWindowOriginsMapToApplicationLocalizationKeys() {
        let now = Date()
        let cached = ModelContextWindows.resolve(model: "custom", reported: AgentModelLimits(contextWindowTokens: 64_000), now: now)
        let table = ModelContextWindows.resolve(model: "gpt-6.1-terra", now: now)
        let fallback = ModelContextWindows.resolve(model: "unknown", now: now)
        let direct = AgentContextResolution(contextWindowTokens: 64_000, source: .api, reason: .reported)
        #expect(ChatContextPresentation.sourceKey(cached) == "chat.context.api_cached")
        #expect(ChatContextPresentation.sourceKey(table) == "chat.context.table")
        #expect(ChatContextPresentation.sourceKey(fallback) == "chat.context.fallback")
        #expect(ChatContextPresentation.sourceKey(direct) == "chat.context.api")
    }

    @Test func originAndDiagnosticsSurviveStepSerializationWithoutRecomputation() throws {
        var timeline = AgentRunTrace()
        timeline.apply(.runStarted)
        let origin = AgentContextResolution(contextWindowTokens: 32_768, source: .fixedFallback, reason: .unknownModel)
        timeline.apply(.contextResolved(origin))
        let diagnostic = AgentDiagnostic(runID: UUID(), sequence: 1, kind: .limitReached,
                                         metrics: [.toolCalls: 51], stopReason: .toolCallLimit, resolutionID: origin.id)
        timeline.apply(.diagnostic(diagnostic))
        let data = try JSONEncoder().encode(timeline.steps)
        let restored = try JSONDecoder().decode([AgentRunStep].self, from: data)
        #expect(restored[0].contextResolution == origin)
        #expect(restored[1].diagnostic == diagnostic)
        #expect(ChatStepPresentation.visibleSteps(restored).count == 2)
        #expect(ChatStepPresentation(step: restored[0]).key == "chat.step.context")
        #expect(ChatStepPresentation(step: restored[1]).key == "chat.diagnostic.limitReached")
        #expect(ChatContextPresentation.diagnosticDetails(diagnostic, localize: { $0 })
            .contains("chat.metric.toolCalls: 51"))
    }

    @Test func oldStepsHaveNoInventedWindowSource() throws {
        let json = """
        {"id":"\(UUID())","kind":"tool","status":"finished","toolName":"list_sources"}
        """
        let restored = try JSONDecoder().decode(AgentRunStep.self, from: Data(json.utf8))
        #expect(restored.contextResolution == nil)
        #expect(restored.diagnostic == nil)
    }
}
