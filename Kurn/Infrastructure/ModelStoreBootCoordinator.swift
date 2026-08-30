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
//  only become visibly relevant for the two cases this PR targets: a
//  background-only launch while the device is locked, and a genuine open
//  failure.
//

import Foundation
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
/// itself `Sendable` (`ModelStoreBootState`, `ModelContainer?`) or a
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

    private let makeStore: @MainActor () throws -> ModelContainer
    private let isProtectedDataAvailable: @MainActor () -> Bool

    init(
        makeStore: @escaping @MainActor () throws -> ModelContainer = { try ModelContainerBootstrap.makeStore() },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = ModelStoreBootCoordinator.systemProtectedDataAvailable
    ) {
        self.makeStore = makeStore
        self.isProtectedDataAvailable = isProtectedDataAvailable
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
    /// volume — that may have cleared).
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
        state = .opening
        do {
            let container = try makeStore()
            self.container = container
            state = .ready
        } catch {
            state = .recoveryRequired(ModelStoreOpenFailure(classifying: error))
        }
    }

    private static func systemProtectedDataAvailable() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }
}
