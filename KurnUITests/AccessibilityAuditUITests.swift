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

    /// The four Meeting Detail tabs share one launch: every test here
    /// relaunches the app, and that launch (not the audit) was most of each
    /// test's ~20-70 s on CI, so auditing the tabs as four tests paid for the
    /// same launch and navigation four times. Each tab is its own activity,
    /// and `continueAfterFailure` is on for this test only, so a failing tab
    /// is still named in the report and the remaining tabs are still audited.
    ///
    /// Seeded data has no semantic index, so the Chat tab only reaches its
    /// empty/disabled state and composer — not the conversation UI (thinking
    /// row, streaming reply, retry, citations), which needs a real answer
    /// from a configured provider and so stays a manual/on-device check.
    func testMeetingDetailTabs() throws {
        openFirstMeeting()
        continueAfterFailure = true

        for tab in ["recordings", "transcript", "summary", "chat"] {
            XCTContext.runActivity(named: "Audit the \(tab) tab") { _ in
                let button = app.buttons["tab.\(tab)"]
                XCTAssertTrue(button.waitForExistence(timeout: 10), "Tab \(tab) missing")
                button.tap()
                do {
                    try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
                } catch {
                    XCTFail("Accessibility audit of the \(tab) tab failed: \(error)")
                }
            }
        }
    }

    func testSettings() throws {
        app.buttons["nav.settings"].tap()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    private func openFirstMeeting() {
        let card = app.buttons["meetingCard"].firstMatch
        let detailTab = app.buttons["tab.recordings"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        for _ in 0..<2 {
            card.tap()
            if detailTab.waitForExistence(timeout: 10) { return }
        }

        XCTFail("Meeting detail did not open")
    }
}
