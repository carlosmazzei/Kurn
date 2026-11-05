import Dispatch

struct BlockingWorkGate: Sendable {
    private let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)

    init() {
        let stream = AsyncStream<Void>.makeStream()
        started = stream.stream
        continuation = stream.continuation
    }

    func block() {
        continuation.yield(())
        release.wait()
    }

    func waitUntilStarted() async {
        for await _ in started { return }
    }

    func resume() {
        release.signal()
    }
}
