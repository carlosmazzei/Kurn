//
//  ProviderCircuitBreakerTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ProviderCircuitBreakerTests {
    @Test func transientFailuresBackOffAndPersist() async {
        let store = InMemoryProviderCircuitStore()
        let clock = MutableDateClock()
        let breaker = ProviderCircuitBreaker(store: store, now: { clock.now })

        await breaker.recordFailure(providerID: "openai", failure: .transient)
        #expect(await breaker.allows(providerID: "openai", trigger: .automatic) == false)
        #expect(await breaker.allows(providerID: "openai", trigger: .explicit))

        clock.advance(by: ProviderCircuitBreaker.transientDelays[0] + 1)
        let restored = ProviderCircuitBreaker(store: store, now: { clock.now })
        #expect(await restored.allows(providerID: "openai", trigger: .automatic))

        await restored.recordFailure(providerID: "openai", failure: .transient)
        let record = await restored.record(for: "openai")
        #expect(record?.consecutiveFailures == 2)
        #expect(record?.blockedUntil == clock.now.addingTimeInterval(
            ProviderCircuitBreaker.transientDelays[1]
        ))
    }

    @Test func configurationFailureRequiresExplicitSuccessfulRetry() async {
        let clock = MutableDateClock()
        let breaker = ProviderCircuitBreaker(
            store: InMemoryProviderCircuitStore(),
            now: { clock.now }
        )

        await breaker.recordFailure(providerID: "anthropic", failure: .configuration)
        clock.advance(by: 365 * 86_400)
        #expect(await breaker.allows(providerID: "anthropic", trigger: .automatic) == false)
        #expect(await breaker.allows(providerID: "anthropic", trigger: .explicit))

        await breaker.recordSuccess(providerID: "anthropic")
        #expect(await breaker.allows(providerID: "anthropic", trigger: .automatic))
        #expect(await breaker.record(for: "anthropic") == nil)
    }

    @Test func ambiguousFailureDoesNotBlockOtherProviders() async {
        let breaker = ProviderCircuitBreaker(store: InMemoryProviderCircuitStore())
        await breaker.recordFailure(providerID: "openai", failure: .ambiguous)

        #expect(await breaker.allows(providerID: "openai", trigger: .automatic) == false)
        #expect(await breaker.allows(providerID: "google", trigger: .automatic))
    }

    @Test func corruptStorageFailsClosedUntilExplicitSuccess() async {
        let store = RecoverableProviderCircuitStore()
        let breaker = ProviderCircuitBreaker(store: store)

        #expect(await breaker.allows(providerID: "openai", trigger: .automatic) == false)
        #expect(await breaker.allows(providerID: "openai", trigger: .explicit))

        await breaker.recordSuccess(providerID: "openai")
        #expect(await breaker.allows(providerID: "openai", trigger: .automatic))
        let restored = ProviderCircuitBreaker(store: store)
        #expect(await restored.allows(providerID: "openai", trigger: .automatic))
    }

    @Test func openingAndClosingTheCircuitAreDurableReliabilityEvents() async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let breaker = ProviderCircuitBreaker(store: InMemoryProviderCircuitStore())
        // The handler is process-global and tests run in parallel, so the
        // provider ID must be one no other test emits events for.
        let providerID = "durable-events-\(UUID().uuidString)"

        await breaker.recordSuccess(providerID: providerID)
        await breaker.recordFailure(providerID: providerID, failure: .transient)
        await breaker.recordFailure(providerID: providerID, failure: .configuration)
        await breaker.recordSuccess(providerID: providerID)

        let events = capture.recorded.filter { $0.operation == "provider_circuit" && $0.stage == providerID }
        #expect(events.map(\.code) == ["circuit_open_transient", "circuit_open_configuration", "circuit_closed"])
        #expect(events.map(\.outcome) == [.failed, .failed, .succeeded])
        #expect(events.map(\.attempt) == [1, 2, 0])
    }

    @Test func resetClearsAConfigurationBlockWithoutRequiringAnExplicitSuccess() async {
        let breaker = ProviderCircuitBreaker(store: InMemoryProviderCircuitStore())

        await breaker.recordFailure(providerID: "openai", failure: .configuration)
        #expect(await breaker.allows(providerID: "openai", trigger: .automatic) == false)

        // Editing the provider's config (e.g. fixing a bad API key) resets
        // the circuit even though no request has succeeded yet — the only
        // way automatic AI-title generation, which has no explicit retry
        // path, could ever recover from a `requiresExplicitRetry` block.
        await breaker.reset(providerID: "openai")
        #expect(await breaker.allows(providerID: "openai", trigger: .automatic))
        #expect(await breaker.record(for: "openai") == nil)
    }

    @Test func resetOnAProviderWithNoRecordIsANoOp() async {
        let breaker = ProviderCircuitBreaker(store: InMemoryProviderCircuitStore())
        await breaker.reset(providerID: "openai")
        #expect(await breaker.allows(providerID: "openai", trigger: .automatic))
    }

    @Test func errorsAreClassifiedWithoutPersistingTheirMessages() {
        #expect(ProviderCircuitFailure(error: AppError.ambiguousProviderResult) == .ambiguous)
        #expect(ProviderCircuitFailure(error: AppError.invalidProviderURL) == .configuration)
        #expect(ProviderCircuitFailure(error: AppError.apiError(
            statusCode: 401,
            message: "secret response"
        )) == .configuration)
        #expect(ProviderCircuitFailure(error: AppError.apiError(
            statusCode: 503,
            message: "secret response"
        )) == .transient)
        #expect(ProviderCircuitFailure(error: AppError.networkError(
            URLError(.notConnectedToInternet)
        )) == .transient)
    }
}

private final class InMemoryProviderCircuitStore: ProviderCircuitStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ProviderCircuitRecord] = [:]

    func load() -> [String: ProviderCircuitRecord] {
        lock.withLock { records }
    }

    func save(_ records: [String: ProviderCircuitRecord]) {
        lock.withLock { self.records = records }
    }
}

private final class RecoverableProviderCircuitStore: ProviderCircuitStateStoring, @unchecked Sendable {
    private enum StoreError: Error { case corrupt }

    private let lock = NSLock()
    private var shouldFailLoad = true
    private var records: [String: ProviderCircuitRecord] = [:]

    func load() throws -> [String: ProviderCircuitRecord] {
        try lock.withLock {
            if shouldFailLoad { throw StoreError.corrupt }
            return records
        }
    }

    func save(_ records: [String: ProviderCircuitRecord]) {
        lock.withLock {
            self.records = records
            shouldFailLoad = false
        }
    }
}

private final class MutableDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}
