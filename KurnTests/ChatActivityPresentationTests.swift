import AgentHarness
import Foundation
import Testing
@testable import Kurn

/// The run as the chat shows it: reasoning, narration and tool calls in order, technical steps
/// kept apart, and the live status line's wording.
struct ChatActivityPresentationTests {
    private func step(_ kind: AgentRunStep.Kind, _ status: AgentRunStep.Status = .finished,
                      configure: (inout AgentRunStep) -> Void = { _ in }) -> AgentRunStep {
        var step = AgentRunStep(kind: kind, status: status)
        configure(&step)
        return step
    }

    @Test func entriesFollowTheRunAndTechnicalStepsGoToDetails() {
        let context = step(.context) { $0.contextResolution = AgentContextResolution(contextWindowTokens: 1, source: .fixedFallback,
                                                                                      reason: .unknownModel) }
        let turn = step(.turn)
        let thinking = step(.thinking) {
            $0.text = "Which meetings?"
            $0.startedAt = Date(timeIntervalSince1970: 0)
            $0.finishedAt = Date(timeIntervalSince1970: 11.6)
        }
        let narration = step(.narration) { $0.text = "Searching." }
        let tool = step(.tool) { $0.toolName = "search"; $0.outputSummary = "\n  5 passages\nmore" }
        let empty = step(.narration) { $0.text = "" }
        let stop = step(.stop) { $0.stopReason = .completed }
        let limit = step(.stop) { $0.stopReason = .toolCallLimit }
        let activity = ChatActivityPresentation(steps: [context, turn, thinking, narration, tool, empty, stop, limit])

        #expect(activity.entries == [
            .thinking(id: thinking.id, text: "Which meetings?", seconds: 12, isRunning: false),
            .narration(id: narration.id, text: "Searching."),
            .tool(id: tool.id, step: tool, result: "5 passages"),
            .notice(id: limit.id, step: limit)
        ])
        #expect(activity.details == [context])
        #expect(!activity.isEmpty && ChatActivityPresentation(steps: [turn, stop]).isEmpty)
    }

    @Test func reasoningLabelsAndResultLines() {
        let localize: (String) -> String = { ["chat.activity.thought_for": "Thought for %d s"][$0] ?? $0 }
        #expect(ChatActivityPresentation.thinkingLabel(seconds: nil, isRunning: true, localize: localize) == "chat.activity.thinking")
        #expect(ChatActivityPresentation.thinkingLabel(seconds: 3, isRunning: false, localize: localize) == "Thought for 3 s")
        #expect(ChatActivityPresentation.thinkingLabel(seconds: nil, isRunning: false, localize: localize) == "chat.activity.reasoning")
        // A sub-second block still reads as one second.
        let quick = step(.thinking) { $0.startedAt = Date(timeIntervalSince1970: 0); $0.finishedAt = Date(timeIntervalSince1970: 0.2) }
        #expect(ChatActivityPresentation(steps: [quick]).entries.first == .thinking(id: quick.id, text: "", seconds: 1, isRunning: false))

        #expect(ChatActivityPresentation.resultLine(nil) == nil)
        #expect(ChatActivityPresentation.resultLine("  \n ") == nil)
        let long = String(repeating: "x", count: 200)
        #expect(ChatActivityPresentation.resultLine(long) == String(repeating: "x", count: ChatActivityPresentation.resultLineLimit) + "…")
    }

    @Test func theLiveStatusSaysWhatTheRunIsDoing() {
        let open = step(.thinking, .running)
        #expect(ChatActivityPresentation.statusKey(phase: .streaming, steps: [open]) == "chat.activity.thinking")
        #expect(ChatActivityPresentation.statusKey(phase: .streaming, steps: [step(.thinking)]) == "chat.activity.writing")
        #expect(ChatActivityPresentation.statusKey(phase: .preparing, steps: []) == "chat.activity.preparing")
        #expect(ChatActivityPresentation.statusKey(phase: .executingTools, steps: []) == "chat.activity.using_tools")
        for phase in [ChatRunPhase.compacting, .retryWaiting, .cancelling, .idle] {
            #expect(ChatActivityPresentation.statusKey(phase: phase, steps: [open]) == nil)
        }

        let localize: (String) -> String = { $0 == "chat.activity.tokens" ? "%@ tokens" : $0 }
        #expect(ChatActivityPresentation.tokenText(0, localize: localize) == nil)
        #expect(ChatActivityPresentation.tokenText(950, localize: localize) == "950 tokens")
        let thousands = ChatActivityPresentation.tokenText(1_234, localize: localize)
        #expect(thousands?.hasSuffix("k tokens") == true && thousands?.hasPrefix("1") == true)
    }

    @Test func reasoningAndNarrationStepsHaveTitles() {
        #expect(ChatStepPresentation(step: step(.thinking)).key == "chat.activity.reasoning")
        #expect(ChatStepPresentation(step: step(.narration)).key == "chat.activity.narration")
    }
}
