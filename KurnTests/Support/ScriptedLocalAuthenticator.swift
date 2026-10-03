//
//  ScriptedLocalAuthenticator.swift
//  KurnTests
//
//  A `LocalAuthenticator` that succeeds or throws a chosen error, counting
//  how often it was asked — the real `LAContext` cannot complete in a test.
//

import Foundation
@testable import Kurn

final class ScriptedLocalAuthenticator: LocalAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Error?
    private var _callCount = 0

    /// `nil` succeeds; anything else is thrown from `evaluate`.
    init(failure: Error? = nil) {
        self.failure = failure
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func evaluate(reason: String) async throws {
        lock.withLock { _callCount += 1 }
        if let failure { throw failure }
    }
}
