//
//  ModelStoreBootCoordinator.swift
//  Kurn
//
//  Replaces the recoverable `fatalError` in `KurnApp`'s old `modelContainer`
//  initializer with an explicit four-state machine
//  (docs/resilience-megaplan.md, H2 PR 3): `waitingForProtectedData`,
//  `opening`, `ready`, `recoveryRequired`. `KurnApp` reads `state` to decide
//  what to render instead of assuming a container always exists.
//
//  Store construction stays synchronous (`ModelContainerBootstrap.makeStore`
//  already is), so on the common path — protected data available, store opens
//  cleanly — `beginBoot()` resolves straight to `.ready` before `KurnApp`'s
//  `body` is ever evaluated, exactly like before this file existed. The states
//  only become visibly relevant for the two cases H2 PR 3 targets — a
//  background-only launch while the device is locked, and a genuine open
//  failure — plus H2 PR 4's protection-verification failure below.
//
//  H2 PR 4 adds two more steps around the open attempt itself: a protected
//  backup is taken before every attempt (so a migration always has a
//  known-good copy behind it — see `ModelStoreBackupManager`), and the
//  store's file protection is verified, not merely applied, after a
//  successful open (`ModelStoreProtection.applyAndVerify`). Both failure
//  modes route through the same `.recoveryRequired` state as an open
//  failure, since both are just as launch-blocking.
//

import Foundation
import KurnCore
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum ModelStoreBootState: Equatable, Sendable {
    case waitingForProtectedData
    case opening
    case ready
    case recoveryRequired(ModelStoreOpenFailure)
}

/// `@MainActor`/`@Observable`: `KurnApp`'s `body` reads `state` directly, and
/// every mutation happens on the main actor exactly where the old inline
/// container construction ran. `Sendable` is a deliberate, checked
/// conformance rather than `@unchecked`: every stored property is either
/// itself `Sendable` (`ModelStoreBootState`, `ModelContainer?`, `URL`) or a
/// `@MainActor`-isolated function type, which the compiler already treats as
/// safely `Sendable` since calling it is structurally serialized through the
/// actor. This is what lets `KurnApp` hand a reference to
/// `TranscriptionScheduler.register`'s `@Sendable` launch-handler closure.
@MainActor
@Observable
final class ModelStoreBootCoordinator: Sendable {
    private(set) var state: ModelStoreBootState = .waitingForProtectedData
    /// Set only on the transition into `.ready`; `KurnApp` reads this once to
    /// build its app-wide coordinators and never needs it again.
    private(set) var container: ModelContainer?
    /// Set when the most recent open attempt's pre-open backup threw. Opening
    /// still proceeds (see `attemptOpen`), but the miss is a durability gap
    /// Health & Recovery must be able to show rather than a log line only.
    private(set) var preOpenBackupFailed = false
    /// Correlates every reliability event this launch's boot emits; the
    /// attempt counter distinguishes the initial open from user retries.
    private let bootRunID = OperationID()
    private var openAttempts = 0
    /// Where the live store (and, under it, `StoreRecovery/`'s backups and
    /// quarantine) lives. Exposed so `KurnApp` can point
    /// `ModelStoreRecoveryViewModel` at the identical location without
    /// re-deriving Application Support itself. When Application Support could
    /// not be resolved at all this is a placeholder under `temporaryDirectory`
    /// that is never opened, backed up or restored into: `attemptOpen()` routes
    /// straight to `.recoveryRequired(.applicationSupportUnavailable)` and the
    /// recovery UI hides every store-file action for that reason.
    let appSupportDirectory: URL
    private let isAppSupportDirectoryResolved: Bool

    private let makeStore: @MainActor () throws -> ModelContainer
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private let createBackupBeforeOpen: @MainActor () throws -> Void
    private let verifyProtectionAfterOpen: @MainActor () throws -> Void

    init(
        appSupportDirectory: URL? = ModelStoreBootCoordinator.systemAppSupportDirectory(),
        makeStore: @escaping @MainActor () throws -> ModelContainer = { try ModelContainerBootstrap.makeStore() },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = ModelStoreBootCoordinator.systemProtectedDataAvailable,
        createBackupBeforeOpen: (@MainActor () throws -> Void)? = nil,
        verifyProtectionAfterOpen: (@MainActor () throws -> Void)? = nil
    ) {
        self.isAppSupportDirectoryResolved = appSupportDirectory != nil
        let appSupportDirectory = appSupportDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("UnresolvedAppSupport", isDirectory: true)
        self.appSupportDirectory = appSupportDirectory
        self.makeStore = makeStore
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.createBackupBeforeOpen = createBackupBeforeOpen ?? {
            try ModelStoreBackupManager(appSupportDirectory: appSupportDirectory).createBackupIfLiveStoreExists()
        }
        self.verifyProtectionAfterOpen = verifyProtectionAfterOpen ?? {
            try ModelStoreProtection.applyAndVerify(appSupportOverride: appSupportDirectory)
        }
    }

    /// Called once from `KurnApp.init()`, after background callbacks are
    /// already registered (see `TranscriptionScheduler.register`) and before
    /// anything else touches the store.
    func beginBoot() {
        attemptOpen()
    }

    /// Called on every foreground activation. A no-op once `.ready`; retries
    /// after `.waitingForProtectedData` (a locked launch that has since
    /// unlocked) or `.recoveryRequired` (the user tapping Retry, or a
    /// transient condition — low storage, an unlocked-but-still-settling
    /// volume — that may have cleared). Also how `KurnApp` re-enters after a
    /// restore or confirmed fresh start replaces the live store files.
    func retryIfNeeded() {
        switch state {
        case .ready, .opening:
            return
        case .waitingForProtectedData, .recoveryRequired:
            attemptOpen()
        }
    }

    private func attemptOpen() {
        guard isProtectedDataAvailable() else {
            state = .waitingForProtectedData
            return
        }
        openAttempts += 1
        // Never open, back up or verify against a volatile placeholder: a store
        // that lands in `tmp/` would report `.ready` and then vanish.
        guard isAppSupportDirectoryResolved else {
            fail(ModelStoreOpenFailure(reason: .applicationSupportUnavailable))
            return
        }
        state = .opening

        // Best-effort: a backup failure must never block opening the store
        // it was trying to protect. Recorded, not surfaced as a boot failure —
        // the H2 PR 4 acceptance bar is "the original is never lost to a
        // migration without one", not "the app cannot launch without one".
        do {
            try createBackupBeforeOpen()
            preOpenBackupFailed = false
        } catch {
            preOpenBackupFailed = true
            AppLog.persistence.atError.error(
                "modelStoreBoot: pre-open backup failed code=\(error.publicLogCode, privacy: .public)"
            )
            report(stage: "backup", outcome: .failed, code: "pre_open_backup_failed")
        }

        do {
            let container = try makeStore()
            do {
                try verifyProtectionAfterOpen()
            } catch {
                // The store opened, but its protection could not be
                // verified — per the megaplan, that is a visible privacy
                // failure, not an unprotected fallback path. Discard the
                // container rather than hand out an unverified one.
                fail(ModelStoreOpenFailure(reason: .protectionVerificationFailed))
                return
            }
            self.container = container
            state = .ready
            report(stage: "open", outcome: .succeeded, code: nil)
        } catch {
            fail(ModelStoreOpenFailure(classifying: error))
        }
    }

    private func fail(_ failure: ModelStoreOpenFailure) {
        state = .recoveryRequired(failure)
        report(stage: "open", outcome: .failed, code: failure.logCode)
    }

    private func report(stage: String, outcome: ReliabilityEvent.Outcome, code: String?) {
        ReliabilityLog.record(ReliabilityEvent(
            operationID: bootRunID,
            operation: "model_store_boot",
            stage: stage,
            outcome: outcome,
            attempt: openAttempts - 1,
            code: code
        ))
    }

    private static func systemProtectedDataAvailable() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }

    /// `nil` when Application Support cannot be resolved or created; the
    /// coordinator then refuses to open rather than fall back to a directory
    /// the system may purge.
    static func systemAppSupportDirectory() -> URL? {
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
        } catch {
            AppLog.persistence.atError.error(
                "modelStoreBoot: application support unavailable code=\(error.publicLogCode, privacy: .public)"
            )
            return nil
        }
    }
}
