//
//  AppOrientationLockTests.swift
//  KurnTests
//
//  `AppOrientationLock` is a process-wide singleton, so the suite is
//  `.serialized` and every lock is balanced by an unlock.
//

import Testing
import UIKit
@testable import Kurn

@MainActor
@Suite(.serialized)
struct AppOrientationLockTests {

    private struct GeometryFailure: Error {}

    /// UIKit calls the handler on a background queue; one inheriting the
    /// main actor would trap here instead of returning.
    @Test func geometryFailureHandlerRunsOffTheMainActor() async {
        let finished = await Task.detached {
            AppOrientationLock.geometryUpdateFailed(GeometryFailure())
            return true
        }.value
        #expect(finished)
    }

    /// The test host's scene is not necessarily active, so UIKit may reject
    /// the request; either way it must come back without trapping.
    @Test func portraitGeometryRequestOnTheHostSceneDoesNotTrap() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        AppOrientationLock.shared.requestPortraitGeometry(on: scene)
        // Give a rejected request time to call its error handler.
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test func lockPinsPortraitUntilEveryNestedLockIsReleased() {
        let lock = AppOrientationLock.shared
        let before = lock.mask

        lock.lockToPortrait()
        lock.lockToPortrait()
        #expect(lock.mask == .portrait)

        lock.unlock()
        #expect(lock.mask == .portrait)

        lock.unlock()
        #expect(lock.mask == before)
    }
}
