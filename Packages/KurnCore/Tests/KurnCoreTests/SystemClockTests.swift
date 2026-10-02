//
//  SystemClockTests.swift
//  KurnCoreTests
//
//  The production clock behind `SleepClock`: monotonic, and `sleep` both
//  waits and honors cancellation (tests use `ManualSleepClock` instead).
//

import Foundation
import Testing
@testable import KurnCore

struct SystemClockTests {

    @Test func nowIsMonotonicAndSleepWaits() async throws {
        let clock = SystemClock()
        let before = clock.now
        try await clock.sleep(seconds: 0.02)
        #expect(clock.now - before >= 0.015)
    }

    @Test func sleepThrowsWhenCancelled() async {
        let task = Task {
            try await SystemClock().sleep(seconds: 30)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
