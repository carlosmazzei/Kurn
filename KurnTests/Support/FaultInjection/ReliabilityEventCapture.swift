//
//  ReliabilityEventCapture.swift
//  KurnTests
//
//  `ReliabilityLog.handler` is one process-global `@Sendable` closure, and
//  Swift Testing runs suites in parallel: two tests each assigning it and then
//  resetting it to `nil` overwrite one another, so whichever installed second
//  swallows the first one's events. Captures therefore never touch the handler
//  directly — they register with `ReliabilityEventCaptureHub`, which owns the
//  handler for the life of the process and fans every event out to all
//  registered captures. Each test still filters by its own operation ID /
//  provider / operation name, because every capture sees every event.
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

    /// Starts receiving events. Pair with `uninstall()` in a `defer`.
    func install() {
        ReliabilityEventCaptureHub.shared.add(self)
    }

    func uninstall() {
        ReliabilityEventCaptureHub.shared.remove(self)
    }
}

final class ReliabilityEventCaptureHub: @unchecked Sendable {
    static let shared = ReliabilityEventCaptureHub()

    private let lock = NSLock()
    private var captures: [ObjectIdentifier: ReliabilityEventCapture] = [:]

    private init() {}

    func add(_ capture: ReliabilityEventCapture) {
        lock.lock(); defer { lock.unlock() }
        if captures.isEmpty {
            ReliabilityLog.handler = { event in
                ReliabilityEventCaptureHub.shared.dispatch(event)
            }
        }
        captures[ObjectIdentifier(capture)] = capture
    }

    func remove(_ capture: ReliabilityEventCapture) {
        lock.lock(); defer { lock.unlock() }
        captures.removeValue(forKey: ObjectIdentifier(capture))
        if captures.isEmpty {
            ReliabilityLog.handler = nil
        }
    }

    private func dispatch(_ event: ReliabilityEvent) {
        let targets = lock.withLock { Array(captures.values) }
        for capture in targets {
            capture.record(event)
        }
    }
}
