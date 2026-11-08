import AgentHarness
import Testing
import KurnCore
@testable import Kurn

struct ChatRunNoticeTests {
    @Test(arguments: [AgentRunStopReason.turnLimit, .toolCallLimit, .costLimit, .outputLimit])
    func limitsKeepPartialAnswersAndMakeEmptyAnswersRetryable(reason: AgentRunStopReason) {
        var stop = AgentRunStep(kind: .stop, status: .finished)
        stop.stopReason = reason
        #expect(ChatRunNotice.needsRetry(steps: [stop], answer: " \n "))
        #expect(!ChatRunNotice.needsRetry(steps: [stop], answer: "Partial"))
        let localize: (String) -> String = { key in
            if key == "chat.limit.retry" { return "%@. Retry." }
            if key == "chat.limit.stopped" { return "Stopped: %@." }
            return "limit"
        }
        #expect(ChatRunNotice.text(steps: [stop], hasAnswer: false, localize: localize) == "limit. Retry.")
        #expect(ChatRunNotice.text(steps: [stop], hasAnswer: true, localize: localize) == "Stopped: limit.")
    }

    @Test func completedMissingOrUnknownStopsDoNotProduceNotices() {
        var stop = AgentRunStep(kind: .stop, status: .finished)
        #expect(ChatRunNotice.text(steps: [stop], hasAnswer: false, localize: { $0 }) == nil)
        #expect(!ChatRunNotice.needsRetry(steps: [], answer: ""))
        stop.stopReason = .completed
        #expect(!ChatRunNotice.needsRetry(steps: [stop], answer: ""))
        #expect(ChatRunNotice.text(steps: [stop], hasAnswer: true, localize: { $0 }) == nil)
    }
}
