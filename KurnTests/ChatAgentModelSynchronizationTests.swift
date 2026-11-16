import Foundation
import Testing

struct ChatAgentModelSynchronizationTests {
    @Test(.timeLimit(.minutes(1))) func cancellationBeforeRegistrationCannotLoseItsSignal() async {
        let pause = ChatAgentCancellationPause()
        pause.cancel()
        await #expect(throws: CancellationError.self) { try await pause.wait() }
    }

    @Test(.timeLimit(.minutes(1))) func registeredPauseEndsOnlyWhenItsTaskIsCancelled() async throws {
        let pause = ChatAgentCancellationPause()
        let task = Task { try await pause.wait() }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !pause.hasWaiter {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { Issue.record("Pause did not register"); return }
            await Task.yield()
        }
        #expect(!task.isCancelled)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!pause.hasWaiter)
    }
}
