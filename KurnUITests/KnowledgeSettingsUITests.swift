import XCTest

@MainActor
final class KnowledgeSettingsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "UI-Testing-KnowledgeNavigationPrototype", "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    func testKnowledgeSettingsPreviewHasExplicitLocalCostAndNoImplicitBackfill() throws {
        continueAfterFailure = false
        let app = launch()
        app.buttons["root.destination.meetings"].tap()
        let settings = app.buttons["nav.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let knowledge = app.buttons["settings.link.knowledge"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 10)); knowledge.tap()
        let pause = app.switches["knowledge.settings.paused"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-settings-controls")
        XCTAssertTrue(flip(pause, to: "1"))
        XCTAssertTrue(flip(pause, to: "0"))
        let choose = app.buttons["knowledge.settings.choose"]
        for _ in 0..<4 where !choose.isHittable { app.swipeUp() }
        choose.tap()
        let source = app.buttons["knowledge.sourceMeeting"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        app.buttons["knowledge.sources.done"].tap()
        let preview = app.buttons["knowledge.settings.preview"]
        for _ in 0..<4 where !preview.isHittable { app.swipeUp() }
        preview.tap()
        let plan = app.staticTexts["knowledge.settings.plan"]
        for _ in 0..<6 where !plan.exists { app.swipeUp() }
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        let cost = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Estimated provider fees: $0.00")).firstMatch
        for _ in 0..<5 where !cost.isHittable { app.swipeUp() }
        XCTAssertTrue(cost.exists)
        capture(app, named: "knowledge-settings-backfill-preview")
    }

    func testKnowledgeSettingsExclusionsRemoveSourcesFromTheKnowledgePicker() throws {
        continueAfterFailure = false
        let app = launch()
        app.buttons["root.destination.meetings"].tap()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 10)); app.buttons["nav.settings"].tap()
        let knowledge = app.buttons["settings.link.knowledge"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 10)); knowledge.tap()
        let scope = app.buttons["knowledge.settings.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10)); scope.tap()
        let all = app.switches["knowledge.settings.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(flip(all, to: "0"))
        capture(app, named: "knowledge-settings-explicit-empty-scope")
        app.buttons["knowledge.settings.scopeDone"].tap()
        let choose = app.buttons["knowledge.settings.choose"]
        for _ in 0..<4 where !choose.isHittable { app.swipeUp() }
        choose.tap()
        XCTAssertTrue(app.buttons["knowledge.sources.done"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "knowledge.sourceMeeting").count, 0)
    }

    /// A Form toggle's element spans its whole row, and a tap at the row's centre lands
    /// on the label, which does not flip it. Tap the switch's own control at the trailing
    /// edge and wait for the value to settle instead of reading it immediately.
    private func flip(_ toggle: XCUIElement, to value: String) -> Bool {
        let control = toggle.switches.firstMatch
        if control.exists { control.tap() } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        return XCTWaiter().wait(for: [settled], timeout: 5) == .completed
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
