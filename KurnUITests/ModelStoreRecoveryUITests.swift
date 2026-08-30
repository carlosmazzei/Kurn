//
//  ModelStoreRecoveryUITests.swift
//  KurnUITests
//
//  Launches the real app with a DEBUG-only synthetic store-open failure
//  injected (`Kurn/DebugSupport/ModelStoreDebugInjection.swift`) and asserts
//  the H2 boot state machine's recovery shell renders instead of crashing or
//  showing real app content — the acceptance bar
//  docs/resilience-megaplan.md's PR 3 sets ("Locked background launch and
//  injected open failures do not crash-loop", "Release-configuration launch
//  tests cover each classified failure"). This is a Debug-configuration
//  launch, matching how AccessibilityAuditUITests/ScreenshotUITests already
//  run in this scheme; a true Release-configuration device run remains a
//  release-checklist item, the same status H1's real-device matrix carries.
//

import XCTest

@MainActor
final class ModelStoreRecoveryUITests: XCTestCase {

    private func launchedApp(reasonRawValue: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING_STORE_OPEN_FAILURE_REASON"] = reasonRawValue
        app.launch()
        return app
    }

    private func assertRecoveryShellAppears(_ app: XCUIApplication) {
        let title = app.staticTexts["storeRecovery.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let retryButton = app.buttons["storeRecovery.retryButton"]
        XCTAssertTrue(retryButton.exists)
        // Real app content must never render underneath a failed boot.
        XCTAssertFalse(app.buttons["nav.settings"].exists)
    }

    func testProtectedDataUnavailableShowsRecoveryShell() {
        assertRecoveryShellAppears(launchedApp(reasonRawValue: "protectedDataUnavailable"))
    }

    func testStorageFullShowsRecoveryShell() {
        assertRecoveryShellAppears(launchedApp(reasonRawValue: "storageFull"))
    }

    func testMigrationIncompatibleShowsRecoveryShell() {
        assertRecoveryShellAppears(launchedApp(reasonRawValue: "migrationIncompatible"))
    }

    func testCorruptOrUnknownShowsRecoveryShell() {
        assertRecoveryShellAppears(launchedApp(reasonRawValue: "corruptOrUnknown"))
    }

    func testRetryDoesNotCrashWhenTheFailureIsStillPresent() {
        let app = launchedApp(reasonRawValue: "corruptOrUnknown")
        assertRecoveryShellAppears(app)

        app.buttons["storeRecovery.retryButton"].tap()

        // The synthetic failure is deterministic, so retry fails again —
        // the shell must still be showing, not a crash and not stale
        // content from a half-completed transition.
        assertRecoveryShellAppears(app)
    }

    func testLockedBackgroundLaunchShowsProgressShellWithoutCrashing() {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-StoreWaitingForProtectedData"]
        app.launch()

        // `.any` rather than a specific element-type query: SwiftUI maps an
        // indeterminate `ProgressView()` to a platform accessibility element
        // type that isn't worth pinning down here — the identifier is what
        // this test actually cares about.
        XCTAssertTrue(app.descendants(matching: .any)["storeLaunch.progress"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nav.settings"].exists)
    }
}
