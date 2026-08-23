//
//  AccessibilityAuditUITests.swift
//  KurnUITests
//
//  Runs `XCUIApplication.performAccessibilityAudit()` over the screens covered
//  by the accessibility pass (see the "Fase 0-8" plan): Meetings List, the
//  Meeting Detail tabs, and Settings. Reuses the "UI-Testing-Screenshots"
//  launch argument for seeded mock data and a bypassed lock screen — the same
//  mechanism ScreenshotUITests uses — so navigation is deterministic without
//  a real recording/microphone in play.
//
//  Scoped to `.sufficientElementDescription` and `.trait`, the two audit
//  categories this pass actually addresses (missing VoiceOver labels/hints,
//  missing button traits). `.contrast` and `.dynamicType` are left out
//  deliberately: the Dynamic Type migration and a full contrast pass are
//  still pending (see the plan), so auditing for them now would fail on
//  pre-existing issues this PR doesn't touch rather than catch regressions.
//  Broaden to `.all` once those phases land.
//

import XCTest

@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots"]
        app.launch()
    }

    func testMeetingsList() throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testMeetingDetailRecordings() throws {
        openFirstMeeting()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testMeetingDetailTranscript() throws {
        openFirstMeeting()
        app.buttons["tab.transcript"].tap()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testMeetingDetailSummary() throws {
        openFirstMeeting()
        app.buttons["tab.summary"].tap()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testSettings() throws {
        app.buttons["nav.settings"].tap()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    private func openFirstMeeting() {
        app.buttons["meetingCard"].firstMatch.tap()
    }
}
