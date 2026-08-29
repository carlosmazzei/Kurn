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
//  `_Concurrency.Clock`, and scoped to the one operation callers actually
//  need: sleeping for a duration. `SystemClock` is the production adapter;
//  test doubles that record requested durations without waiting live beside
//  the callers that use them (see `KurnTests/Support/FaultInjection/`).
//

import Foundation

public protocol SleepClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: SleepClock {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
