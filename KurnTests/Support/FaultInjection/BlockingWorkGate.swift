import Dispatch
import Synchronization
import Testing

final class BlockingWorkGate: Sendable {
    private struct State: Sendable {
        var started = false
        var cancel: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let release = DispatchSemaphore(value: 0)

    func block() {
        let cancel = state.withLock {
            $0.started = true
            return $0.cancel
        }
        cancel?()
        #expect(release.wait(timeout: .now() + 30) == .success)
    }

    /// Register before awaiting the task, so cancellation needs no free cooperative worker.
    func cancelWhenStarted<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) {
        let cancel: @Sendable () -> Void = { [release] in
            task.cancel()
            release.signal()
        }
        let alreadyStarted = state.withLock {
            $0.cancel = cancel
            return $0.started
        }
        if alreadyStarted { cancel() }
    }
}
