import XCTest

@MainActor
final class MeetingKnowledgeUITests: XCTestCase {
    private func launch(largeType: Bool = false, prototype: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if prototype { app.launchArguments += ["UI-Testing-KnowledgeNavigationPrototype"] }
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
        let content = app.descendants(matching: .any)["knowledge.content"].firstMatch
        _ = quote.waitForExistence(timeout: 5)
        for _ in 0..<8 where !quote.isHittable { content.swipeUp() }
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
        let content = app.descendants(matching: .any)["knowledge.content"].firstMatch
        for _ in 0..<4 where !notes.isHittable { content.swipeDown() }
        XCTAssertTrue(notes.exists)
        notes.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The team reported")).firstMatch.waitForExistence(timeout: 5))
        capture(app, named: "knowledge-meeting-notes")
    }

    func testKnowledgeAtAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = launch(largeType: true)
        openKnowledge(app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-meeting-accessibility")
        let content = app.descendants(matching: .any)["knowledge.content"].firstMatch
        content.swipeDown()
        content.swipeDown()
        capture(app, named: "knowledge-meeting-accessibility-overview")
    }

    func testEntityEvidenceAndTranscriptFromMeeting() throws {
        continueAfterFailure = false
        let app = launch()
        openKnowledge(app)
        let entity = app.buttons["knowledge.openEntity"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 10))
        entity.tap()
        let claim = app.staticTexts["knowledge.browser.claim"].firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 10))
        XCTAssertTrue(claim.label.contains("Example portal"))
        capture(app, named: "knowledge-entity-overview")
        let sources = app.buttons["knowledge.browser.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        let evidence = app.buttons["knowledge.browser.evidence"].firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-entity-sources")
        evidence.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.quote"].waitForExistence(timeout: 10))
        capture(app, named: "knowledge-evidence-detail")
        app.buttons["knowledge.browser.openTranscript"].tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.citedSegment"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["knowledge.browser.play"].exists)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-source-transcript")
    }

    func testKnowledgeRootNavigationPrototype() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 15))
        capture(app, named: "knowledge-navigation-home-prototype")
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(app.buttons["meetingCard"].firstMatch.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-meetings-prototype")
        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["Ask is not available in this preview."].waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-ask-prototype")
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
