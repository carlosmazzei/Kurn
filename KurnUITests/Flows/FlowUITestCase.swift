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
//  (menu-picker options) are called out at the site, and the language is
//  pinned to English so those stay valid on a simulator set to any other.
//
//  Stability rules every flow follows (CLAUDE.md, "Accessibility"):
//  - never sleep; wait for a condition (`waitForExistence`, `waitUntil`);
//  - a tap that starts a transition is checked by what it should produce,
//    and repeated once if it was dropped (`tapUntilCovered`, `tap(_:until:)`);
//  - UIKit animations are off (`UITestLaunchOptions.disableAnimations`);
//  - every launch starts from the same in-memory seed, and anything a flow
//    creates carries a per-launch suffix, so no test depends on another.
//

import XCTest

@MainActor
class FlowUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "UI-Testing-Screenshots",
            "UI-Testing-DisableAnimations",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
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
        // The hub is a lazy `Form`: a row below the fold is not in the
        // hierarchy at all until scrolled to, so wait for the hub itself, then
        // swipe until the row materializes.
        XCTAssertTrue(app.buttons["settings.link.providers"].waitForExistence(timeout: 10), "Settings hub missing")
        let row = app.buttons[identifier]
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings row \(identifier) missing")
        scrollIntoSafeArea(row)
        XCTAssertTrue(tapUntilCovered(row), "Settings row \(identifier) did not open its screen")
    }

    /// Waits up to `timeout` for `predicate` to hold for `element`.
    @discardableResult
    func waitUntil(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Taps an element that pushes or presents a screen, and confirms the new
    /// screen covered it. A tap that lands while the previous transition is
    /// still settling is dropped without an error, so the tap is repeated once
    /// when the element is still hittable afterwards.
    @discardableResult
    func tapUntilCovered(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        for _ in 0..<2 {
            element.tap()
            if waitUntil(element, "hittable == false", timeout: timeout) { return true }
        }
        return false
    }

    /// Taps `element` until `outcome` appears, retrying once if the first tap
    /// produced nothing and `element` can still be tapped.
    @discardableResult
    func tap(_ element: XCUIElement, until outcome: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        for _ in 0..<2 {
            element.tap()
            if outcome.waitForExistence(timeout: timeout) { return true }
            guard element.exists, element.isHittable else { break }
        }
        return outcome.exists
    }

    /// Rows at the bottom of the Settings hub sit under the home indicator /
    /// sheet edge, where a tap lands but does nothing. Nudge the list until
    /// the row is comfortably inside the window.
    func scrollIntoSafeArea(_ element: XCUIElement, maxSwipes: Int = 4) {
        let limit = app.frame.maxY - 120
        for _ in 0..<maxSwipes where !element.isHittable || element.frame.maxY > limit {
            app.swipeUp()
        }
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

    /// Taps the back button that returns to the screen titled `title`. A
    /// `NavigationStack` keeps the parent bar in the hierarchy, so the first
    /// navigation-bar button is not reliably the visible back button; the
    /// back button's label is the previous screen's title.
    func goBack(to title: String) {
        let back = app.navigationBars.buttons[title]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back button to \(title) missing")
        back.tap()
    }

    /// Swipe-action buttons do not always expose the identifier set on them,
    /// so match either the identifier or the visible label.
    func swipeActionButton(identifier: String, label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Swipes the cell that contains `row` (falling back to the row itself)
    /// until the swipe action appears; a swipe on a partially covered row
    /// can be swallowed, so retry once.
    func revealSwipeAction(on row: XCUIElement, identifier: String, label: String) -> XCUIElement {
        let action = swipeActionButton(identifier: identifier, label: label)
        let cell = app.cells.containing(NSPredicate(format: "identifier == %@", row.identifier)).firstMatch
        for _ in 0..<2 where !action.exists {
            (cell.exists ? cell : row).swipeLeft()
            _ = action.waitForExistence(timeout: 3)
        }
        return action
    }

    /// Scrolls the visible list until `element` exists. `List` rows are
    /// lazily created, so a row below the fold is absent from the hierarchy
    /// until it scrolls into view.
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if element.waitForExistence(timeout: 2) { return true }
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 2)
    }

    /// The visible text of a menu-style `Picker`: SwiftUI exposes the selected
    /// option as a child static text, not as the picker element's own value.
    func pickerValue(_ picker: XCUIElement) -> String {
        if let value = picker.value as? String, !value.isEmpty { return value }
        let texts = picker.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        let joined = texts.joined(separator: " ")
        return joined.isEmpty ? picker.label : joined
    }

    /// Dumps the element tree into the test log so a CI failure can be
    /// diagnosed without a local simulator.
    override func record(_ issue: XCTIssue) {
        // `NSLog` truncates long messages, so emit the tree a few lines at a time.
        let lines = app.debugDescription.split(separator: "\n", omittingEmptySubsequences: false)
        for chunk in stride(from: 0, to: lines.count, by: 8) {
            let slice = lines[chunk..<min(chunk + 8, lines.count)].joined(separator: "\n")
            NSLog("[FlowUITest] hierarchy %d:\n%@", chunk, slice)
        }
        super.record(issue)
    }
}
