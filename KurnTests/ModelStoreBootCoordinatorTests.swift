//
//  ModelStoreBootCoordinatorTests.swift
//  KurnTests
//
//  Drives the H2 boot state machine (docs/resilience-megaplan.md, PR 3)
//  through injected `makeStore`/`isProtectedDataAvailable` seams — the same
//  shape `ModelContainerBootstrapTests` already uses for the lower-level
//  factory. Proves the acceptance criteria directly: a locked launch never
//  attempts to open the store, an open failure never crashes and never
//  fabricates a container, and retry only ever re-attempts from a
//  non-`.ready` state.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ModelStoreBootCoordinatorTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func locksBeginBootIntoWaitingWithoutAttemptingToOpen() {
        final class Spy: @unchecked Sendable { var openAttempts = 0 }
        let spy = Spy()
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { spy.openAttempts += 1; return try self.makeInMemoryContainer() },
            isProtectedDataAvailable: { false }
        )

        coordinator.beginBoot()

        #expect(coordinator.state == .waitingForProtectedData)
        #expect(coordinator.container == nil)
        #expect(spy.openAttempts == 0)
    }

    @Test func opensDirectlyToReadyWhenProtectedDataIsAvailable() throws {
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { try self.makeInMemoryContainer() },
            isProtectedDataAvailable: { true }
        )

        coordinator.beginBoot()

        #expect(coordinator.state == .ready)
        #expect(coordinator.container != nil)
    }

    @Test func classifiesAThrownOpenFailureIntoRecoveryRequired() {
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) },
            isProtectedDataAvailable: { true }
        )

        coordinator.beginBoot()

        #expect(coordinator.state == .recoveryRequired(ModelStoreOpenFailure(reason: .storageFull)))
        #expect(coordinator.container == nil)
    }

    @Test func retryIfNeededIsANoOpOnceReady() {
        final class Spy: @unchecked Sendable { var openAttempts = 0 }
        let spy = Spy()
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { spy.openAttempts += 1; return try self.makeInMemoryContainer() },
            isProtectedDataAvailable: { true }
        )
        coordinator.beginBoot()
        #expect(spy.openAttempts == 1)

        coordinator.retryIfNeeded()

        #expect(spy.openAttempts == 1)
        #expect(coordinator.state == .ready)
    }

    @Test func retryIfNeededReattemptsAfterWaitingForProtectedData() {
        final class ProtectionToggle: @unchecked Sendable { var isAvailable = false }
        let toggle = ProtectionToggle()
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { try self.makeInMemoryContainer() },
            isProtectedDataAvailable: { toggle.isAvailable }
        )
        coordinator.beginBoot()
        #expect(coordinator.state == .waitingForProtectedData)

        toggle.isAvailable = true
        coordinator.retryIfNeeded()

        #expect(coordinator.state == .ready)
        #expect(coordinator.container != nil)
    }

    @Test func retryIfNeededReattemptsAfterRecoveryRequired() {
        final class FailureToggle: @unchecked Sendable { var shouldFail = true }
        let toggle = FailureToggle()
        let coordinator = ModelStoreBootCoordinator(
            makeStore: {
                if toggle.shouldFail {
                    throw NSError(domain: "test", code: 1)
                }
                return try self.makeInMemoryContainer()
            },
            isProtectedDataAvailable: { true }
        )
        coordinator.beginBoot()
        #expect(coordinator.state == .recoveryRequired(ModelStoreOpenFailure(reason: .corruptOrUnknown)))

        toggle.shouldFail = false
        coordinator.retryIfNeeded()

        #expect(coordinator.state == .ready)
        #expect(coordinator.container != nil)
    }

    @Test func neverFabricatesAContainerAfterAFailure() {
        // The acceptance criterion in its most literal form: a failed open
        // must never leave `container` non-nil, which is what would let
        // `KurnApp` accidentally render real app content over a failed boot.
        let coordinator = ModelStoreBootCoordinator(
            makeStore: { throw NSError(domain: "test", code: 1) },
            isProtectedDataAvailable: { true }
        )

        coordinator.beginBoot()

        #expect(coordinator.container == nil)
        guard case .recoveryRequired = coordinator.state else {
            Issue.record("Expected .recoveryRequired, got \(coordinator.state)")
            return
        }
    }
}
