import AgentHarness
import Foundation
import Testing
@testable import KurnCore

struct ChatContextTraceTests {
    @Test func originAndDiagnosticsSurviveStepSerializationWithoutRecomputation() throws {
        var timeline = ChatAgentTimeline()
        timeline.apply(.runStarted)
        let origin = AgentContextResolution(contextWindowTokens: 32_768, source: .fixedFallback, reason: .unknownModel)
        timeline.apply(.contextResolved(origin))
        let diagnostic = AgentDiagnostic(runID: UUID(), sequence: 1, kind: .limitReached,
                                         metrics: [.toolCalls: 51], stopReason: .toolCallLimit, resolutionID: origin.id)
        timeline.apply(.diagnostic(diagnostic))
        let data = try JSONEncoder().encode(timeline.steps)
        let restored = try JSONDecoder().decode([ChatAgentStep].self, from: data)
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
        let restored = try JSONDecoder().decode(ChatAgentStep.self, from: Data(json.utf8))
        #expect(restored.contextResolution == nil)
        #expect(restored.diagnostic == nil)
    }
}
