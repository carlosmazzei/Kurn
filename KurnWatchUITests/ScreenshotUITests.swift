//
//  ScreenshotUITests.swift
//  KurnWatchUITests
//
//  Drives KurnWatch in App Store screenshot mode: WatchConnectivityManager
//  seeds a mock "recording in progress" state (see
//  KurnWatch/WatchConnectivityManager.swift) whenever the
//  "UI-Testing-Screenshots" launch argument is present, since there is no
//  paired iPhone during a UI test run to drive the real WatchConnectivity
//  session. Run via `bundle exec fastlane screenshots` (fastlane/Fastfile),
//  not as part of the default `iOS CI` build-and-test job.
//

import XCTest

@MainActor
final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["UI-Testing-Screenshots"]
        app.launch()
    }

    func testRecordingRemote() throws {
        snapshot("01Recording")
    }
}
