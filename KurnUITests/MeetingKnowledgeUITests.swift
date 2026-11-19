import XCTest

@MainActor
final class MeetingKnowledgeUITests: XCTestCase {
    private func launch(largeType: Bool = false, prototype: Bool = false, longTranscript: Bool = false, review: Bool = false,
                        graph: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UI-Testing-Screenshots", "UI-Testing-DisableAnimations", "UI-Testing-KnowledgeFixture",
            "-settings.knowledgeEnabled", "YES", "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if prototype { app.launchArguments += ["UI-Testing-KnowledgeNavigationPrototype"] }
        if longTranscript { app.launchArguments += ["UI-Testing-KnowledgeLongTranscript"] }
        if review { app.launchArguments += ["UI-Testing-KnowledgeReviewFixture"] }
        if graph { app.launchArguments += ["UI-Testing-KnowledgeGraphFixture"] }
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

    func testTimelineOpensFromHomeAndLeadsToEvidence() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        let timeline = app.buttons["knowledge.browser.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        timeline.tap()
        let entry = app.descendants(matching: .any)["knowledge.timeline.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["knowledge.timeline.filter"].exists)
        assertRootBarFits(app)
        capture(app, named: "knowledge-timeline")
        entry.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.claim"].firstMatch.waitForExistence(timeout: 10))
    }

    func testEntityComparesTwoDates() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        let entity = app.buttons["knowledge.browser.entity"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 15))
        entity.tap()
        let compare = app.buttons["knowledge.browser.compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10))
        compare.tap()
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.compare.from"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.compare.asKnownThen"].firstMatch.exists)
        capture(app, named: "knowledge-compare")
    }

    func testGraphExplorerDrawsListsAndKeepsItsSelection() throws {
        continueAfterFailure = false
        let app = launch(prototype: true, graph: true)
        let entity = app.buttons["knowledge.browser.entity"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 15))
        entity.tap()
        let open = app.buttons["knowledge.browser.graph"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let nodes = app.buttons.matching(identifier: "knowledge.graph.node")
        XCTAssertTrue(nodes.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.graph.claim"].firstMatch.exists)
        capture(app, named: "knowledge-graph")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        // The first entity (the team) is the centre; select the portal, then
        // read the same claims as a list.
        let portal = nodes.matching(NSPredicate(format: "label BEGINSWITH %@", "Example portal")).firstMatch
        XCTAssertTrue(portal.exists)
        portal.tap()
        let selected = app.staticTexts["knowledge.graph.selected"].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertEqual(selected.label.lowercased(), "example portal")
        XCTAssertTrue(app.buttons["knowledge.graph.recentre"].firstMatch.exists)
        app.buttons["List"].firstMatch.tap()
        XCTAssertFalse(nodes.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["knowledge.graph.recentre"].firstMatch.waitForExistence(timeout: 5))
        capture(app, named: "knowledge-graph-list")
        // A page opened from the graph comes back to the list it was left in.
        app.buttons["knowledge.graph.openPage"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.claim"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["knowledge.graph.recentre"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(nodes.firstMatch.exists)
    }

    func testKnowledgeSearchFindsAliasesAndEvidenceWithoutSemanticSearch() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("ORION\n")
        let alias = app.buttons["knowledge.search.result.alias"].firstMatch
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        assertRootBarFits(app)
        capture(app, named: "knowledge-search-alias")
        alias.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.claim"].firstMatch.waitForExistence(timeout: 10))
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let clear = field.buttons["Clear text"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        field.typeText("review\n")
        let claim = app.buttons["knowledge.search.result.assertion"].firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-search-claim")
        claim.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.quote"].waitForExistence(timeout: 10))
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

    func testReviewIdentityMergeAndUndoUseTheRealStore() throws {
        continueAfterFailure = false
        let app = launch(prototype: true, review: true)
        let open = app.buttons["knowledge.review.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let candidate = app.buttons["knowledge.review.candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-review-inbox")
        candidate.tap()
        let merge = app.buttons["knowledge.review.merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        capture(app, named: "knowledge-review-identity")
        merge.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["knowledge.review.confirmMerge"].firstMatch.tap()
        let undo = app.buttons["knowledge.review.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        let list = app.descendants(matching: .any)["knowledge.review.inbox"].firstMatch
        for _ in 0..<5 where !undo.isHittable { list.swipeUp() }
        capture(app, named: "knowledge-review-merge-history")
        undo.tap()
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["knowledge.review.failed"].exists)
    }

    func testReviewCanKeepIdentitiesSeparateAndInspectConflictingEvidence() throws {
        continueAfterFailure = false
        let app = launch(prototype: true, review: true)
        let open = app.buttons["knowledge.review.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let candidate = app.buttons["knowledge.review.candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10)); candidate.tap()
        app.buttons["knowledge.review.dismiss"].tap()
        let dismissed = app.buttons["knowledge.review.dismissed"].firstMatch
        XCTAssertTrue(dismissed.waitForExistence(timeout: 10))
        let list = app.descendants(matching: .any)["knowledge.review.inbox"].firstMatch
        for _ in 0..<5 where !dismissed.isHittable { list.swipeUp() }
        dismissed.tap()
        app.buttons["knowledge.review.reopen"].tap()
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        let warning = app.buttons["Possible conflict"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        for _ in 0..<5 where !warning.isHittable { list.swipeUp() }
        warning.tap()
        let evidence = app.buttons["knowledge.review.evidence"].firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        for _ in 0..<5 where !evidence.isHittable { list.swipeUp() }
        capture(app, named: "knowledge-review-source-warning")
        evidence.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.quote"].waitForExistence(timeout: 10))
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
