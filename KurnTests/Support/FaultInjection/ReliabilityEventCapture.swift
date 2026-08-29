//
//  ReliabilityEventCapture.swift
//  KurnTests
//
//  `ReliabilityLog.handler` is `@Sendable`, so a test cannot capture a plain
//  local `var` in the closure it installs there (Swift 6 strict concurrency
//  rejects mutating a captured variable from a `@Sendable` closure). This is
//  the lock-guarded box every reliability-event proof test installs instead.
//

import Foundation
import KurnCore

final class ReliabilityEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReliabilityEvent] = []

    func record(_ event: ReliabilityEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [ReliabilityEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
