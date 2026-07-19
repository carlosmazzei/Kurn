//
//  ScreenshotUITests.swift
//  KurnUITests
//
//  Drives the app in App Store screenshot mode: KurnApp seeds mock meetings
//  (Kurn/DebugSupport/ScreenshotSeedData.swift) and bypasses the recordings
//  lock screen whenever the "UI-Testing-Screenshots" launch argument is
//  present. Run via `bundle exec fastlane screenshots` (fastlane/Fastfile),
//  not as part of the default `iOS CI` build-and-test job.
//

import XCTest

@MainActor
final class ScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["UI-Testing-Screenshots"]
        app.launch()
    }

    func testMeetingsList() throws {
        snapshot("01Meetings")
    }

    func testMeetingDetailRecordings() throws {
        openFirstMeeting()
        snapshot("02MeetingRecordings")
    }

    func testMeetingDetailTranscript() throws {
        openFirstMeeting()
        app.buttons["tab.transcript"].tap()
        snapshot("03Transcript")
    }

    func testMeetingDetailSummary() throws {
        openFirstMeeting()
        app.buttons["tab.summary"].tap()
        snapshot("04Summary")
    }

    func testSettings() throws {
        app.buttons["nav.settings"].tap()
        snapshot("05Settings")
    }

    private func openFirstMeeting() {
        app.buttons["meetingCard"].firstMatch.tap()
    }
}
