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

    // Synchronous on purpose: waiting through the cooperative executor made this test time out
    // whenever a loaded CI runner starved that pool, although the utility thread had delivered.
    @Test func signalReportsWithoutAManualFlush() {
        let delivered = DispatchSemaphore(value: 0)
        let count = Mutex(0)
        let reporter = CaptureJournalFailureReporter {
            count.withLock { $0 += 1 }
            delivered.signal()
        }
        defer { reporter.stop() }

        reporter.signal()
        // A missing callback fails on this deadline or on the delivery-count assertion.
        #expect(delivered.wait(timeout: .now() + 30) == .success)
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
