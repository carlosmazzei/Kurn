import AgentHarness
import Foundation
import Testing
import KurnCore
@testable import Kurn

struct ChatStepPresentationTests {
    @Test(arguments: ["list_sources", "search", "read_transcript", "read_summary", "read_wiki", "read_attachment",
                      "create_document", "update_document", "append_to_document", "read_document"])
    func knownToolsMapToLocalizedHumanTitles(name: String) {
        let meeting = UUID(), document = UUID()
        var step = AgentRunStep(kind: .tool)
        step.toolName = name
        step.arguments = .object(["query": .string("Roadmap"), "meetingID": .string(meeting.uuidString),
                                  "document_id": .string(document.uuidString)])
        let presentation = ChatStepPresentation(step: step, meetingTitles: [meeting: "Planning"], documentTitles: [document: "Minutes"])
        #expect(presentation.key == "chat.step.\(name)")
        #expect(!presentation.symbol.isEmpty)
        let parameter: String?
        switch name {
        case "list_sources": parameter = nil
        case "search": parameter = "Roadmap"
        case "read_transcript", "read_summary", "read_wiki", "read_attachment": parameter = "Planning"
        default: parameter = "Minutes"
        }
        #expect(presentation.parameter == parameter)
        #expect(presentation.title { _ in "Action %@" } == (parameter.map { "Action \($0)" } ?? "Action %@"))
    }

    @Test func documentTitlesPreferExplicitTitlesAndUnknownArgumentsHaveLocalizedFallbacks() {
        var step = AgentRunStep(kind: .tool)
        step.toolName = "create_document"
        step.arguments = .object(["title": .string("Report")])
        #expect(ChatStepPresentation(step: step).parameter == "Report")
        step.toolName = "read_document"
        step.arguments = .object(["document_id": .string("invalid"), "title": .string("   ")])
        #expect(ChatStepPresentation(step: step).parameterKey == "chat.step.document")
        step.toolName = "read_summary"
        step.arguments = .object(["meetingID": .number(1)])
        #expect(ChatStepPresentation(step: step).parameterKey == "chat.step.meeting")
        step.toolName = "search"
        step.arguments = .null
        let presentation = ChatStepPresentation(step: step)
        #expect(presentation.parameterKey == "chat.step.query")
        #expect(presentation.title { $0 == "chat.step.search" ? "Searching %@" : "query" } == "Searching query")
        step.toolName = "read_unknown"
        #expect(ChatStepPresentation(step: step).key == "chat.step.tool")
        #expect(ChatStepPresentation(step: step).parameter == "read_unknown")
        step.toolName = nil
        #expect(ChatStepPresentation(step: step).parameterKey == "chat.step.tool.unknown")
    }

    @Test func turnCompactionStopsAndVisibleCounts() {
        var turn = AgentRunStep(kind: .turn)
        #expect(ChatStepPresentation(step: turn).parameter == "1")
        turn.turnIndex = 3
        #expect(ChatStepPresentation(step: turn).parameter == "4")
        let compaction = AgentRunStep(kind: .compaction)
        #expect(ChatStepPresentation(step: compaction).key == "chat.step.compaction")
        var stop = AgentRunStep(kind: .stop)
        #expect(ChatStepPresentation(step: stop).key == "chat.step.stop.unknown")
        for reason in [AgentRunStopReason.completed, .turnLimit, .toolCallLimit, .costLimit, .outputLimit] {
            stop.stopReason = reason
            #expect(ChatStepPresentation(step: stop).key == "chat.step.stop.\(reason.rawValue)")
        }
        let tool = AgentRunStep(kind: .tool)
        #expect(ChatStepPresentation.visibleSteps([turn, tool, compaction, stop]) == [tool, compaction, stop])
        stop.stopReason = .completed
        #expect(ChatStepPresentation.visibleSteps([turn, stop]).isEmpty)
        #expect(ChatStepPresentation.visibleSteps([]).isEmpty)
        #expect(ChatStepPresentation.countLabel(1) { _ in "1 step" } == "1 step")
        #expect(ChatStepPresentation.countLabel(3) { _ in "%d steps" } == "3 steps")
    }

    @Test func previewsAreBoundedByScalarsAndHandleEmptyAndInvalidLimits() {
        #expect(ChatStepPresentation.preview("").isEmpty)
        #expect(ChatStepPresentation.preview("abc", limit: 3) == "abc")
        #expect(ChatStepPresentation.preview("你好世界", limit: 2) == "你好…")
        #expect(ChatStepPresentation.preview("abc", limit: -1) == "a…")
        #expect(ChatStepPresentation.preview(String(repeating: "a", count: 3_000)).unicodeScalars.count == 2_001)
    }
}
