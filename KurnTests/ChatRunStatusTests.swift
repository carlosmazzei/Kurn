import Foundation
import Testing
@testable import Kurn

/// NH08: the running row says what the run is doing in words, a retry's wait with its delay.
struct ChatRunStatusTests {
    @Test func eachPhaseHasItsOwnStatus() {
        let running = NSLocalizedString("chat.step.running", comment: "")
        #expect(ChatRunPhase.streaming.statusText(retryDelaySeconds: nil) == running)
        #expect(ChatRunPhase.executingTools.statusText(retryDelaySeconds: nil) == running)
        #expect(ChatRunPhase.compacting.statusText(retryDelaySeconds: nil) == NSLocalizedString("chat.step.compacting", comment: ""))
        #expect(ChatRunPhase.cancelling.statusText(retryDelaySeconds: 3) == NSLocalizedString("chat.step.cancelling", comment: ""))
        #expect(ChatRunPhase.retryWaiting.statusText(retryDelaySeconds: nil) == NSLocalizedString("chat.step.retrying", comment: ""))
        // A partial second rounds up: the wait is never shown shorter than it is.
        #expect(ChatRunPhase.retryWaiting.statusText(retryDelaySeconds: 1.2)
            == String(format: NSLocalizedString("chat.step.retrying_in", comment: ""), 2))
    }
}
