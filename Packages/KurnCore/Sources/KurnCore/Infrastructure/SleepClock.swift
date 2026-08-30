//
//  SleepClock.swift
//  KurnCore
//
//  No abstraction over time existed anywhere in the app before this: every
//  retry/backoff/poll site called `Task.sleep` directly, which means none of
//  them could be driven deterministically in a test — proving a backoff
//  delay meant actually waiting out real seconds, or not proving it at all.
//
//  Named `SleepClock`, not `Clock`, to avoid colliding with
//  `_Concurrency.Clock`. `MonotonicSleepClock` also exposes uptime for operations
//  whose total deadline spans requests and backoff. `SystemClock` is the
//  production adapter; deterministic doubles live beside their callers.
//

import Foundation

public protocol SleepClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public protocol MonotonicSleepClock: SleepClock {
    var now: TimeInterval { get }
}

public struct SystemClock: MonotonicSleepClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
