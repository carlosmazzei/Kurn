import Foundation
import Synchronization

final class CaptureJournalFailureReporter: Sendable {
    typealias ThreadStart = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let pending = Atomic(false)
    private let stopped = Atomic(false)
    private let reported = Atomic(false)
    private let semaphore = DispatchSemaphore(value: 0)
    private let onFailure: @Sendable () -> Void

    init(
        startThread: ThreadStart = CaptureJournalFailureReporter.startThread,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.onFailure = onFailure
        startThread { self.run() }
    }

    func signal() {
        // No allocation or lock: atomic when uncontended, a non-blocking kernel signal with a waiter.
        pending.store(true, ordering: .releasing)
        semaphore.signal()
    }

    func flush() {
        if pending.exchange(false, ordering: .acquiringAndReleasing),
           !reported.exchange(true, ordering: .acquiringAndReleasing) {
            onFailure()
        }
    }

    func stop() {
        stopped.store(true, ordering: .releasing)
        semaphore.signal()
    }

    static func startThread(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.qualityOfService = .utility
        thread.name = "kurn.capture-journal.reporter"
        thread.start()
    }

    private func run() {
        while true {
            semaphore.wait()
            flush()
            if stopped.load(ordering: .acquiring) { return }
        }
    }
}
