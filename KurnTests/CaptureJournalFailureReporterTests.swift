import Foundation
import Synchronization
import Testing
@testable import Kurn

struct CaptureJournalFailureReporterTests {
    private final class Worker: Sendable {
        private let work = Mutex<(@Sendable () -> Void)?>(nil)

        func start(_ body: @escaping @Sendable () -> Void) {
            work.withLock { $0 = body }
        }

        func run() {
            let body = work.withLock {
                let body = $0
                $0 = nil
                return body
            }
            body?()
        }
    }

    @Test(.timeLimit(.minutes(1))) func signalReportsWithoutAManualFlush() async {
        let (delivered, continuation) = AsyncStream<Void>.makeStream()
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter {
            count.withLock { $0 += 1 }
            continuation.yield(())
            continuation.finish()
        }
        defer {
            reporter.stop()
            continuation.finish()
        }

        reporter.signal()
        // Yield the cooperative executor while the real utility thread delivers the signal.
        // A missing callback still fails via the test deadline or the delivery-count assertion.
        for await _ in delivered { break }
        #expect(count.withLock { $0 } == 1)
    }

    @Test func manualFlushAndWorkerReportOnlyOnce() {
        let worker = Worker()
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter(startThread: worker.start) {
            count.withLock { $0 += 1 }
        }

        reporter.signal()
        reporter.flush()
        reporter.flush()
        reporter.stop()
        worker.run()
        #expect(count.withLock { $0 } == 1)
    }

    @Test func repeatedSignalsIncludingAfterDeliveryReportOnlyOnce() {
        let worker = Worker()
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter(startThread: worker.start) {
            count.withLock { $0 += 1 }
        }

        reporter.signal()
        reporter.signal()
        reporter.flush()
        reporter.signal()
        reporter.flush()
        reporter.stop()
        worker.run()
        #expect(count.withLock { $0 } == 1)
    }

    @Test func stopFlushesAPendingFailureBeforeExiting() {
        let worker = Worker()
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter(startThread: worker.start) {
            count.withLock { $0 += 1 }
        }

        reporter.signal()
        reporter.stop()
        worker.run()
        #expect(count.withLock { $0 } == 1)
    }

    @Test func stoppingWithoutAFailureReportsNothing() {
        let worker = Worker()
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter(startThread: worker.start) {
            count.withLock { $0 += 1 }
        }

        reporter.stop()
        worker.run()
        #expect(count.withLock { $0 } == 0)
    }
}
