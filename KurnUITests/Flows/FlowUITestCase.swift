//
//  FlowUITestCase.swift
//  KurnUITests
//
//  Shared launch + navigation for the flow suites in this folder. Every flow
//  launches with "UI-Testing-Screenshots": an in-memory store seeded by
//  `ScreenshotSeedData`, no lock screen, no microphone — the same seam the
//  accessibility audit uses, so a flow never depends on real recordings,
//  downloaded models or a configured cloud provider. Flows only touch elements
//  through `accessibilityIdentifier`s; the few places that still match text
//  (menu-picker options) are called out at the site.
//

import XCTest

@MainActor
class FlowUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots"]
        app.launch()
    }

    /// Opens the Settings hub from the Meetings list.
    func openSettings() {
        let settings = app.buttons["nav.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    /// Pushes one Settings destination by its hub-row identifier.
    func openSettingsScreen(_ identifier: String) {
        openSettings()
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings row \(identifier) missing")
        row.tap()
    }

    /// Opens the first seeded meeting and waits for its detail tabs.
    func openFirstMeeting() {
        let card = app.buttons["meetingCard"].firstMatch
        let detailTab = app.buttons["tab.recordings"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        for _ in 0..<2 {
            card.tap()
            if detailTab.waitForExistence(timeout: 10) { return }
        }

        XCTFail("Meeting detail did not open")
    }

    /// Any element carrying the identifier, regardless of the element type
    /// SwiftUI maps a container (List, Form, VStack) to.
    func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Taps the back button of the top navigation bar.
    func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }
}
