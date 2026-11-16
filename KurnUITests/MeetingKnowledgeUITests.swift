import XCTest

@MainActor
final class MeetingKnowledgeUITests: XCTestCase {
    private func launch(largeType: Bool = false, prototype: Bool = false, longTranscript: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if prototype { app.launchArguments += ["UI-Testing-KnowledgeNavigationPrototype"] }
        if longTranscript { app.launchArguments += ["UI-Testing-KnowledgeLongTranscript"] }
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
        let app = launch(longTranscript: true)
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
        XCTAssertTrue(app.staticTexts["knowledge.browser.citedSegment"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["knowledge.browser.play"].isHittable)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-source-transcript")
    }

    func testKnowledgeRootNavigationPrototype() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        assertRootBarFits(app)
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 15))
        capture(app, named: "knowledge-navigation-home-prototype")
        app.buttons["root.destination.meetings"].tap()
        XCTAssertTrue(app.buttons["meetingCard"].firstMatch.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-meetings-prototype")
        app.buttons["root.destination.ask"].tap()
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        XCTAssertLessThanOrEqual(app.buttons["chat.send"].frame.maxY, app.buttons["root.destination.ask"].frame.minY)
        assertRootBarFits(app)
        capture(app, named: "knowledge-navigation-ask-prototype")
        let documents = app.buttons["root.destination.documents"]
        let newDocument = app.buttons["documents.new"]
        // Match the flow suite's transition-confirmed tap: UIKit can drop a
        // tab tap while the previous screen finishes its first layout.
        for _ in 0..<2 {
            documents.tap()
            if newDocument.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(newDocument.exists)
        let document = app.buttons["documents.open"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-documents")
        document.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Example portal artifact")).firstMatch.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-artifact")
    }

    func testMeetingMenusAndSelectionSurviveRootTabChanges() throws {
        continueAfterFailure = false
        let app = launch()
        let options = app.buttons["meetings.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        assertRootBarFits(app)
        XCTAssertFalse(app.navigationBars.buttons["meetings.record"].exists)
        options.tap()
        XCTAssertTrue(app.buttons["meetings.library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meetings.filters"].exists)
        XCTAssertTrue(app.buttons["meetings.select"].exists)
        XCTAssertTrue(app.buttons["Sort"].exists)
        capture(app, named: "knowledge-navigation-list-options")
        app.buttons["meetings.library"].tap()
        let favorites = app.buttons["library.bucket.favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["meetings.filters"].tap()
        let week = app.segmentedControls.buttons["This week"]
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        week.tap()
        app.navigationBars.buttons["Done"].tap()
        options.tap()
        app.buttons["meetings.select"].tap()
        let done = app.buttons["meetings.selection.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        app.buttons["meetingCard"].firstMatch.tap()
        app.buttons["meetings.selection.actions"].tap()
        XCTAssertTrue(app.buttons["meetings.selection.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meetings.selection.export"].isEnabled)
        XCTAssertTrue(app.buttons["meetings.selection.delete"].exists)
        capture(app, named: "knowledge-navigation-selection-actions")
        // Dismiss outside the two top-right menu rows, without choosing an action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        app.buttons["root.destination.ask"].tap()
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10))
        app.buttons["root.destination.meetings"].tap()
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        options.tap()
        app.buttons["meetings.library"].tap()
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        XCTAssertTrue(favorites.isSelected)
        app.navigationBars.buttons["Done"].tap()
        options.tap()
        app.buttons["meetings.filters"].tap()
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        XCTAssertTrue(week.isSelected)
    }

    func testKnowledgeHomeUsesExplicitSourceSelection() throws {
        continueAfterFailure = false
        let app = launch()
        app.buttons["root.destination.knowledge"].tap()
        let choose = app.buttons["knowledge.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let source = app.buttons["knowledge.sourceMeeting"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.buttons["knowledge.sources.done"].tap()
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-selected-sources")
        choose.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Selected meetings: 1")).firstMatch.exists)
    }

    func testRootNavigationFitsAtAccessibilitySize() throws {
        continueAfterFailure = false
        let app = launch(largeType: true, prototype: true)
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 15))
        assertRootBarFits(app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-navigation-floating-record-accessibility")
        app.buttons["root.destination.meetings"].tap()
        XCTAssertTrue(app.buttons["meetings.options"].waitForExistence(timeout: 10))
        assertRootBarFits(app)
    }

    /// Check actual hit targets and separation, not just that five controls
    /// exist. This catches a recorder drawn over a destination on small bars.
    private func assertRootBarFits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.tabBars.buttons.count, 0, file: file, line: line)
        let record = app.buttons["meetings.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(record.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(record.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(record.frame.height, 44, file: file, line: line)
        for destination in ["meetings", "knowledge", "ask", "documents"] {
            let button = app.buttons["root.destination.\(destination)"]
            XCTAssertTrue(button.isHittable, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, record.frame.minX, file: file, line: line)
            XCTAssertEqual(button.frame.midY, record.frame.midY, accuracy: 4, file: file, line: line)
        }
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
