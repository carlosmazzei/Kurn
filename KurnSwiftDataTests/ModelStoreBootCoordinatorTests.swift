//
//  ModelStoreBootCoordinatorTests.swift
//  KurnTests
//
//  Drives the H2 boot state machine (docs/resilience-megaplan.md, PR 3 and
//  PR 4) through injected `makeStore`/`isProtectedDataAvailable` seams — the
//  same shape `ModelContainerBootstrapTests` already uses for the
//  lower-level factory. Proves the acceptance criteria directly: a locked
//  launch never attempts to open the store, an open failure never crashes
//  and never fabricates a container, retry only ever re-attempts from a
//  non-`.ready` state, a pre-open backup failure never blocks opening, and a
//  post-open protection-verification failure never hands out an unverified
//  container.
//
//  Every coordinator here is given its own temporary `appSupportDirectory`
//  (never the default, real Application Support) — PR 4 added real
//  filesystem I/O (backup creation, protection verification) to
//  `attemptOpen()`, and without an explicit override every test below would
//  otherwise touch the test runner's actual on-disk state.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

// Nested inside `SwiftDataConcurrencySensitiveTests` (Support/) rather than
// a bare `@Suite(.serialized)` at the top level: that trait only serializes
// tests *within* one suite, not across sibling suites, and this suite's real
// in-memory `ModelContainer`s need to never run concurrently with
// `ModelStoreSalvageTests`'s either — see that parent type's header comment.
extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct BootCoordinatorTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func withTempAppSupport(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreBootCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// A coordinator whose backup/verify steps are real (exercise
    /// `ModelStoreBackupManager`/`ModelStoreProtection` for real) but scoped
    /// to `directory`, never the real Application Support.
    private func makeCoordinator(
        in directory: URL,
        makeStore: @escaping @MainActor () throws -> ModelContainer,
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true }
    ) -> ModelStoreBootCoordinator {
        ModelStoreBootCoordinator(
            appSupportDirectory: directory,
            makeStore: makeStore,
            isProtectedDataAvailable: isProtectedDataAvailable
        )
    }

    @Test func locksBeginBootIntoWaitingWithoutAttemptingToOpen() throws {
        try withTempAppSupport { directory in
            final class Spy: @unchecked Sendable { var openAttempts = 0 }
            let spy = Spy()
            let coordinator = makeCoordinator(
                in: directory,
                makeStore: { spy.openAttempts += 1; return try self.makeInMemoryContainer() },
                isProtectedDataAvailable: { false }
            )

            coordinator.beginBoot()

            #expect(coordinator.state == .waitingForProtectedData)
            #expect(coordinator.container == nil)
            #expect(spy.openAttempts == 0)
        }
    }

    @Test func opensDirectlyToReadyWhenProtectedDataIsAvailable() throws {
        try withTempAppSupport { directory in
            let coordinator = makeCoordinator(in: directory, makeStore: { try self.makeInMemoryContainer() })

            coordinator.beginBoot()

            #expect(coordinator.state == .ready)
            #expect(coordinator.container != nil)
        }
    }

    @Test func classifiesAThrownOpenFailureIntoRecoveryRequired() throws {
        try withTempAppSupport { directory in
            let coordinator = makeCoordinator(
                in: directory,
                makeStore: { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
            )

            coordinator.beginBoot()

            #expect(coordinator.state == .recoveryRequired(ModelStoreOpenFailure(reason: .storageFull)))
            #expect(coordinator.container == nil)
        }
    }

    @Test func retryIfNeededIsANoOpOnceReady() throws {
        try withTempAppSupport { directory in
            final class Spy: @unchecked Sendable { var openAttempts = 0 }
            let spy = Spy()
            let coordinator = makeCoordinator(
                in: directory,
                makeStore: { spy.openAttempts += 1; return try self.makeInMemoryContainer() }
            )
            coordinator.beginBoot()
            #expect(spy.openAttempts == 1)

            coordinator.retryIfNeeded()

            #expect(spy.openAttempts == 1)
            #expect(coordinator.state == .ready)
        }
    }

    @Test func retryIfNeededReattemptsAfterWaitingForProtectedData() throws {
        try withTempAppSupport { directory in
            final class ProtectionToggle: @unchecked Sendable { var isAvailable = false }
            let toggle = ProtectionToggle()
            let coordinator = makeCoordinator(
                in: directory,
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
    }

    @Test func retryIfNeededReattemptsAfterRecoveryRequired() throws {
        try withTempAppSupport { directory in
            final class FailureToggle: @unchecked Sendable { var shouldFail = true }
            let toggle = FailureToggle()
            let coordinator = makeCoordinator(
                in: directory,
                makeStore: {
                    if toggle.shouldFail {
                        throw NSError(domain: "test", code: 1)
                    }
                    return try self.makeInMemoryContainer()
                }
            )
            coordinator.beginBoot()
            #expect(coordinator.state == .recoveryRequired(ModelStoreOpenFailure(reason: .corruptOrUnknown)))

            toggle.shouldFail = false
            coordinator.retryIfNeeded()

            #expect(coordinator.state == .ready)
            #expect(coordinator.container != nil)
        }
    }

    @Test func neverFabricatesAContainerAfterAFailure() throws {
        // The acceptance criterion in its most literal form: a failed open
        // must never leave `container` non-nil, which is what would let
        // `KurnApp` accidentally render real app content over a failed boot.
        try withTempAppSupport { directory in
            let coordinator = makeCoordinator(in: directory, makeStore: { throw NSError(domain: "test", code: 1) })

            coordinator.beginBoot()

            #expect(coordinator.container == nil)
            guard case .recoveryRequired = coordinator.state else {
                Issue.record("Expected .recoveryRequired, got \(coordinator.state)")
                return
            }
        }
    }

    // MARK: - H2 PR 4: backup and protection verification

    @Test func backsUpAnExistingLiveStoreBeforeOpening() throws {
        try withTempAppSupport { directory in
            for suffix in [""] + ModelStoreProtection.sidecarSuffixes {
                try Data("existing".utf8).write(to: directory.appendingPathComponent(ModelStoreProtection.baseName + suffix))
            }
            let coordinator = makeCoordinator(in: directory, makeStore: { try self.makeInMemoryContainer() })

            coordinator.beginBoot()

            #expect(coordinator.state == .ready)
            let generations = ModelStoreBackupManager(appSupportDirectory: directory).listGenerations()
            #expect(generations.count == 1)
        }
    }

    @Test func aBackupFailureNeverBlocksOpening() throws {
        // Best-effort by design: a pre-open backup failing must not prevent
        // the store it was trying to protect from opening at all.
        try withTempAppSupport { directory in
            let coordinator = ModelStoreBootCoordinator(
                appSupportDirectory: directory,
                makeStore: { try self.makeInMemoryContainer() },
                isProtectedDataAvailable: { true },
                createBackupBeforeOpen: { throw NSError(domain: "test.backup", code: 1) }
            )

            coordinator.beginBoot()

            #expect(coordinator.state == .ready)
            #expect(coordinator.container != nil)
        }
    }

    @Test func aProtectionVerificationFailureBecomesRecoveryRequiredAndDiscardsTheContainer() throws {
        try withTempAppSupport { directory in
            let coordinator = ModelStoreBootCoordinator(
                appSupportDirectory: directory,
                makeStore: { try self.makeInMemoryContainer() },
                isProtectedDataAvailable: { true },
                verifyProtectionAfterOpen: { throw NSError(domain: "test.verify", code: 1) }
            )

            coordinator.beginBoot()

            #expect(coordinator.state == .recoveryRequired(ModelStoreOpenFailure(reason: .protectionVerificationFailed)))
            #expect(coordinator.container == nil)
        }
    }
}
}
