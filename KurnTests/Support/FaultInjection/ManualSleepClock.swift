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

final class ManualSleepClock: MonotonicSleepClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [TimeInterval] = []
    private var currentTime: TimeInterval

    init(now: TimeInterval = 0) {
        currentTime = now
    }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        // `NSLock.lock()`/`unlock()` are unavailable from an async function
        // body (the compiler can't prove no suspension happens mid-lock);
        // `withLock` is the scoped-locking form that sidesteps that check.
        lock.withLock {
            recordedDurations.append(seconds)
            currentTime += seconds
        }
    }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return currentTime
    }

    var durations: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedDurations
    }
}
