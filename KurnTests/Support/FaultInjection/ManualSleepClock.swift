//
//  ManualSleepClock.swift
//  KurnTests
//
//  A `SleepClock` double that records every requested duration without
//  actually waiting, so a test can assert a production retry/backoff path
//  slept for the durations it computed — deterministically, in milliseconds,
//  instead of really waiting out real seconds (or, previously, not being
//  able to prove the sleep happened at all).
//

import Foundation
import KurnCore

final class ManualSleepClock: SleepClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [TimeInterval] = []

    func sleep(seconds: TimeInterval) async throws {
        lock.lock()
        recordedDurations.append(seconds)
        lock.unlock()
    }

    var durations: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedDurations
    }
}
