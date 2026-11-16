import XCTest

@MainActor
final class MeetingKnowledgeUITests: XCTestCase {
    private func launch(largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    private func openKnowledge(_ app: XCUIApplication) {
        let card = app.buttons["meetingCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            card.tap()
            if app.buttons["tab.knowledge"].waitForExistence(timeout: 10) { break }
        }
        let mode = app.buttons["tab.knowledge"]
        XCTAssertTrue(mode.exists)
        mode.tap()
        let quote = app.staticTexts["knowledge.quote"].firstMatch
        _ = quote.waitForExistence(timeout: 5)
        for _ in 0..<4 where !quote.isHittable { app.swipeUp() }
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
    }

    func testKnowledgeContributionsAndInlineNotes() throws {
        continueAfterFailure = false
        let app = launch()
        openKnowledge(app)
        let header = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "knowledge.header", "Claims: 1")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["knowledge.quote"].firstMatch.label.contains("Example portal"))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-meeting-compact")
        let notes = app.descendants(matching: .any)["knowledge.notes"].firstMatch
        for _ in 0..<4 where !notes.isHittable { app.swipeDown() }
        XCTAssertTrue(notes.exists)
        notes.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "The team reported")).firstMatch.waitForExistence(timeout: 5))
        capture(app, named: "knowledge-meeting-notes")
    }

    func testKnowledgeAtAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = launch(largeType: true)
        openKnowledge(app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-meeting-accessibility")
        app.swipeDown()
        app.swipeDown()
        capture(app, named: "knowledge-meeting-accessibility-overview")
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
