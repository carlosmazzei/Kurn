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
        // Sleep rather than yield between polls: a yielding loop keeps a
        // cooperative thread busy, and with the rest of the suite running in
        // parallel the task it waits for may not get one in time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !pause.hasWaiter {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { Issue.record("Pause did not register"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!task.isCancelled)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!pause.hasWaiter)
    }
}
