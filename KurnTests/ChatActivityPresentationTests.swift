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

    @Test func successiveCallsOfOneToolFoldIntoAGroup() {
        let first = UUID(), second = UUID(), third = UUID()
        func read(_ meeting: UUID) -> AgentRunStep {
            step(.tool) { $0.toolName = "read_transcript"; $0.arguments = .object(["meetingID": .string(meeting.uuidString)]) }
        }
        let reads = [read(first), read(second), read(third), read(first)]
        let search = step(.tool) { $0.toolName = "search" }
        let narration = step(.narration) { $0.text = "Now reading." }
        let activity = ChatActivityPresentation(steps: [search, narration] + reads + [search])
        #expect(activity.entries.count == 4 && activity.actionCount == 6)
        guard case .toolGroup(let id, let name, let grouped) = activity.entries[2] else {
            Issue.record("expected a group"); return
        }
        #expect(id == reads[0].id && name == "read_transcript" && grouped == reads)

        let titles = [first: "Budget", second: "Kickoff", third: "Retro"]
        #expect(ChatActivityPresentation.groupResult(reads, meetingTitles: titles, documentTitles: [:]) == "Budget, Kickoff, +1")
        #expect(ChatActivityPresentation.groupResult(Array(reads.prefix(2)), meetingTitles: titles, documentTitles: [:])
                == "Budget, Kickoff")
        let unknown = [step(.tool) { $0.toolName = "x" }, step(.tool) { $0.toolName = "x" }]
        #expect(ChatActivityPresentation.groupResult(unknown, meetingTitles: [:], documentTitles: [:]) == nil)

        let localize: (String) -> String = { $0 == "chat.activity.group.read_transcript" ? "Read %d transcripts" : "%d \($0)" }
        #expect(ChatActivityPresentation.groupTitle(name: "read_transcript", count: 3, localize: localize) == "Read 3 transcripts")
        #expect(ChatActivityPresentation.groupTitle(name: "x", count: 2, localize: localize) == "2 chat.activity.group.other")

        #expect(ChatActivityPresentation.groupStatus([read(first), step(.tool, .failed)]) == .failed)
        #expect(ChatActivityPresentation.groupStatus([step(.tool, .failed), step(.tool, .running)]) == .running)
        #expect(ChatActivityPresentation.groupStatus(reads) == .finished)
    }

    @Test func aFinishedRunFoldsIntoOneSummaryLine() {
        let localize: (String) -> String = {
            ["chat.activity.thought_for": "Thought for %d s", "chat.activity.actions.one": "1 action",
             "chat.activity.actions.count": "%d actions", "chat.activity.reasoning": "Reasoning"][$0] ?? $0
        }
        func thought(_ seconds: TimeInterval?) -> AgentRunStep {
            step(.thinking) {
                $0.startedAt = seconds.map { _ in Date(timeIntervalSince1970: 0) }
                $0.finishedAt = seconds.map { Date(timeIntervalSince1970: $0) }
            }
        }
        let tools = (0..<3).map { _ in step(.tool) { $0.toolName = "search" } }
        #expect(ChatActivityPresentation(steps: [thought(5), tools[0], thought(7)] + tools.dropFirst())
            .summary(localize: localize) == "Thought for 12 s · 3 actions")
        #expect(ChatActivityPresentation(steps: [thought(nil), tools[0]]).summary(localize: localize) == "Reasoning · 1 action")
        #expect(ChatActivityPresentation(steps: [tools[0]]).summary(localize: localize) == "1 action")
        #expect(ChatActivityPresentation(steps: [step(.narration) { $0.text = "x" }]).summary(localize: localize) == nil)
    }
}
