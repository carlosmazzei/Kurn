//
//  RecordingAccessGateTests.swift
//  KurnTests
//
//  Drives `RecordingAccessGate` through a stub `LocalAuthenticator` so the
//  state-machine behavior (unlock, failure surfacing, lock reset, coalescing
//  of concurrent prompts) is observable without invoking the real
//  `LAContext` — which cannot complete in a unit-test environment.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct RecordingAccessGateTests {

    @Test func startsLocked() {
        let gate = RecordingAccessGate(authenticator: StubAuthenticator(result: .success))
        #expect(gate.isUnlocked == false)
        #expect(gate.lastError == nil)
    }

    @Test func successfulAuthenticationUnlocksAndClearsError() async {
        let gate = RecordingAccessGate(authenticator: StubAuthenticator(result: .success))
        await gate.authenticate()
        #expect(gate.isUnlocked == true)
        #expect(gate.lastError == nil)
    }

    @Test func failedAuthenticationSurfacesErrorAndStaysLocked() async {
        let gate = RecordingAccessGate(
            authenticator: StubAuthenticator(result: .failure("canceled"))
        )
        await gate.authenticate()
        #expect(gate.isUnlocked == false)
        guard case .authenticationFailed(let detail) = gate.lastError else {
            Issue.record("expected authenticationFailed; got \(String(describing: gate.lastError))")
            return
        }
        #expect(detail.contains("canceled"))
    }

    @Test func lockResetsUnlockedStateAndError() async {
        let gate = RecordingAccessGate(authenticator: StubAuthenticator(result: .success))
        await gate.authenticate()
        #expect(gate.isUnlocked == true)
        gate.lock()
        #expect(gate.isUnlocked == false)
        #expect(gate.lastError == nil)
    }

    @Test func authenticationCallsAreCoalesced() async {
        let authenticator = StubAuthenticator(result: .success)
        let gate = RecordingAccessGate(authenticator: authenticator)

        async let first: Void = gate.authenticate()
        async let second: Void = gate.authenticate()
        async let third: Void = gate.authenticate()
        _ = await (first, second, third)

        #expect(gate.isUnlocked == true)
        // All three callers share a single underlying evaluation.
        #expect(authenticator.callCount == 1)
    }

    @Test func reAuthenticatingAfterLockEvaluatesAgain() async {
        let authenticator = StubAuthenticator(result: .success)
        let gate = RecordingAccessGate(authenticator: authenticator)

        await gate.authenticate()
        gate.lock()
        await gate.authenticate()

        #expect(gate.isUnlocked == true)
        #expect(authenticator.callCount == 2)
    }

    @Test func isAuthenticatingIsTrueWhileInFlightAndFalseAfter() async {
        let authenticator = StubAuthenticator(result: .success)
        let gate = RecordingAccessGate(authenticator: authenticator)
        #expect(gate.isAuthenticating == false)

        let task = Task { await gate.authenticate() }
        while !gate.isAuthenticating {
            await Task.yield()
        }
        #expect(gate.isAuthenticating == true)

        await task.value
        #expect(gate.isAuthenticating == false)
    }
}

private final class StubAuthenticator: LocalAuthenticator, @unchecked Sendable {
    enum Result {
        case success
        case failure(String)
    }

    private let lock = NSLock()
    private let result: Result
    private var _callCount = 0

    init(result: Result) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func evaluate(reason: String) async throws {
        let outcome = lock.withLock {
            _callCount += 1
            return result
        }
        // Yield once so concurrent callers can observe the in-flight task.
        await Task.yield()
        switch outcome {
        case .success:
            return
        case .failure(let detail):
            throw NSError(
                domain: "StubAuthenticator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
