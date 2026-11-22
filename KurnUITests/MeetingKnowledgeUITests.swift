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
        app.buttons["detail.more"].tap()
        XCTAssertTrue(app.buttons["Archive"].firstMatch.waitForExistence(timeout: 5))
        // The Knowledge tab's own "Regenerate Wiki" chip stays; the menu has no wiki items.
        XCTAssertTrue(app.buttons["knowledge.generateNotes"].exists)
        for label in ["View wiki", "Generate Wiki", "Regenerate Wiki"] {
            let menuItem = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, "knowledge.generateNotes"))
            XCTAssertEqual(menuItem.count, 0, label)
        }
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
        XCTAssertTrue(claim.label.contains("Open"))
        capture(app, named: "knowledge-entity-overview")
        app.buttons["knowledge.entity.actions"].tap()
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
        XCTAssertTrue(app.buttons["knowledge.browser.entity"].firstMatch.waitForExistence(timeout: 15))
        capture(app, named: "knowledge-navigation-home-prototype")
        closeSheet(app)
        assertRootBarFits(app)
        XCTAssertTrue(app.buttons["meetingCard"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["root.destination.meetings"].exists)
        capture(app, named: "knowledge-navigation-meetings-prototype")
        app.buttons["root.destination.ask"].tap()
        // A seeded launch has no provider key, so the composer isn't rendered.
        XCTAssertFalse(app.buttons["chat.send"].waitForExistence(timeout: 3))
        capture(app, named: "knowledge-navigation-ask-prototype")
        closeSheet(app)
        let documents = app.buttons["root.destination.documents"]
        let newDocument = app.buttons["documents.new"]
        // Match the flow suite's transition-confirmed tap: UIKit can drop a
        // tap while the previous sheet finishes dismissing.
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

    func testMeetingControlsAreUnifiedAtTopAndBottomAndKeepTheirState() throws {
        continueAfterFailure = false
        let app = launch()
        let library = app.buttons["meetings.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        assertRootBarFits(app)
        // List options (Filters, Sort, Select) share one trailing menu beside
        // Settings; recording stays in its own group in the bottom bar.
        let actions = app.buttons["meetings.actions"]
        let settings = app.buttons["nav.settings"]
        for control in [actions, settings] {
            XCTAssertTrue(control.isHittable)
            XCTAssertLessThan(control.frame.midY, library.frame.minY)
        }
        XCTAssertFalse(app.navigationBars.buttons["meetings.record"].exists)
        capture(app, named: "knowledge-navigation-list-controls")
        let firstCardBeforeSort = app.buttons["meetingCard"].firstMatch.label
        actions.tap()
        let sort = app.buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        let oldest = app.buttons["Oldest first"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        oldest.tap()
        XCTAssertNotEqual(app.buttons["meetingCard"].firstMatch.label, firstCardBeforeSort)
        actions.tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        let newest = app.buttons["Newest first"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        newest.tap()
        library.tap()
        let favorites = app.buttons["library.bucket.favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        actions.tap()
        let filters = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "meetings.filters", "Filters")
        ).firstMatch
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        let week = app.buttons["This week"]
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        week.tap()
        // The filter sheet applies via its "Show N" confirmation, not a Done.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show ")).firstMatch.tap()
        actions.tap()
        let select = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "meetings.select", "Select")
        ).firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let done = app.buttons["meetings.selection.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        app.buttons["meetingCard"].firstMatch.tap()
        XCTAssertTrue(app.buttons["meetings.selection.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meetings.selection.export"].isEnabled)
        XCTAssertTrue(app.buttons["meetings.selection.delete"].exists)
        capture(app, named: "knowledge-navigation-selection-actions")
        done.tap()
        app.buttons["root.destination.ask"].tap()
        // No provider key in the seeded fixture: the composer isn't rendered.
        XCTAssertFalse(app.buttons["chat.send"].waitForExistence(timeout: 3))
        closeSheet(app)
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        XCTAssertTrue(favorites.isSelected)
        app.navigationBars.buttons["Done"].tap()
        actions.tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        XCTAssertTrue(week.isSelected)
    }

    func testKnowledgeButtonWhenDisabledShowsSettingsPrompt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "UI-Testing-Screenshots",
            "UI-Testing-DisableAnimations",
            "UI-Testing-ResetDefaults",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        assertRootBarFits(app)
        let knowledge = app.buttons["root.destination.knowledge"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 10))
        knowledge.tap()
        XCTAssertTrue(app.staticTexts["A wiki of your meetings"].waitForExistence(timeout: 10))
        let openSettings = app.buttons["knowledge.openSettings"]
        XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
        openSettings.tap()
        let toggle = app.switches["knowledge.settings.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.switches.firstMatch.tap()
        let done = app.navigationBars.allElementsBoundByIndex.last?.buttons["Done"].firstMatch
            ?? app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["knowledge.chooseSources"].waitForExistence(timeout: 10))
    }

    func testKnowledgeHomeUsesExplicitSourceSelection() throws {
        continueAfterFailure = false
        let app = launch()
        let knowledge = app.buttons["root.destination.knowledge"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 10))
        knowledge.tap()
        let choose = app.buttons["knowledge.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        // The home preselects this week's meetings; the seeded knowledge
        // meeting is the newest one (first row), so toggle a different row to
        // keep its facts in scope.
        let source = app.buttons.matching(identifier: "knowledge.sourceMeeting").element(boundBy: 1)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.buttons["knowledge.sources.done"].tap()
        let entity = app.buttons["knowledge.browser.entity"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-navigation-selected-sources")
        choose.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(entity.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["knowledge.chooseSources"].label.contains("meeting"))
        // The selection belongs to the meetings screen: closing the sheet and
        // opening Knowledge again reads the same meetings.
        closeSheet(app)
        XCTAssertTrue(knowledge.waitForExistence(timeout: 10))
        knowledge.tap()
        XCTAssertTrue(entity.waitForExistence(timeout: 10))
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
        app.buttons["knowledge.entity.actions"].tap()
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
        capture(app, named: "knowledge-graph")
        // The mode controls sit above the drawing, so the selected node's
        // claims start below the fold of a lazy list: scroll to them and back.
        XCTAssertTrue(revealGraphClaim(app))
        for _ in 0..<3 where !nodes.firstMatch.isHittable { app.swipeDown() }
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
        readerBackButton(app).tap()
        XCTAssertTrue(app.buttons["knowledge.graph.recentre"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(nodes.firstMatch.exists)
        // Comparing two days: the undated blocker holds on both, so it stays.
        for _ in 0..<4 where !app.buttons["Compare"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["Compare"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.graph.from"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.graph.to"].firstMatch.exists)
        XCTAssertTrue(revealGraphClaim(app))
        capture(app, named: "knowledge-graph-compare")
        for _ in 0..<4 where !app.buttons["On a day"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["On a day"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["knowledge.graph.day"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(revealGraphClaim(app))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        // Context lanes: every relationship names the context it was said in.
        for _ in 0..<4 where !app.buttons["Contexts"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["Contexts"].firstMatch.tap()
        let inContext = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Context: Example vendor sync")).firstMatch
        XCTAssertTrue(reveal(inContext, in: app))
        capture(app, named: "knowledge-graph-lanes-list")
        // The drawing: each node's label names its lane.
        for _ in 0..<4 where !app.buttons["Graph"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["Graph"].firstMatch.tap()
        let lanedNode = nodes.matching(NSPredicate(format: "label CONTAINS %@", "Context: Example vendor sync")).firstMatch
        XCTAssertTrue(lanedNode.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-graph-lanes")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    func testKnowledgeSearchFindsAliasesAndEvidenceWithoutSemanticSearch() throws {
        continueAfterFailure = false
        let app = launch(prototype: true)
        // The meetings list's own search field stays in the hierarchy under
        // the Knowledge sheet, so pick the reader's field by its prompt.
        let field = app.searchFields["Search pages and facts"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("ORION\n")
        let alias = app.buttons["knowledge.search.result.alias"].firstMatch
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        capture(app, named: "knowledge-search-alias")
        alias.tap()
        XCTAssertTrue(app.staticTexts["knowledge.browser.claim"].firstMatch.waitForExistence(timeout: 10))
        let back = readerBackButton(app)
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
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        closeSheet(app)
        assertRootBarFits(app)
        XCTAssertTrue(app.buttons["meetings.library"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture(app, named: "knowledge-navigation-floating-record-accessibility")
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
        let confirm = app.buttons["dialog.primary"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
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

    /// The bottom bar holds Library, Knowledge, Ask, and Documents in one group
    /// and, in its own group to their right, the record button, all on one row.
    private func assertRootBarFits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.tabBars.buttons.count, 0, file: file, line: line)
        let record = app.buttons["meetings.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(record.isHittable, file: file, line: line)
        let bottomControls = [
            app.buttons["meetings.library"],
            app.buttons["root.destination.knowledge"],
            app.buttons["root.destination.ask"],
            app.buttons["root.destination.documents"]
        ]
        for button in bottomControls {
            XCTAssertTrue(button.isHittable, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, record.frame.minX, file: file, line: line)
            XCTAssertEqual(button.frame.midY, record.frame.midY, accuracy: 8, file: file, line: line)
        }
    }

    /// The back button of the Knowledge sheet's own navigation bar. The meetings
    /// list's bar stays in the hierarchy under the sheet and comes first, so the
    /// sheet's bar is the last one.
    private func readerBackButton(_ app: XCUIApplication) -> XCUIElement {
        let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
        let back = bar.buttons["BackButton"]
        return back.exists ? back : bar.buttons.element(boundBy: 0)
    }

    /// Closes the sheet on top (Knowledge or Ask) through its Done button.
    private func closeSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), file: file, line: line)
        done.tap()
        XCTAssertTrue(app.buttons["root.destination.knowledge"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// The graph's mode controls sit above its claims, which a lazy list
    /// only creates once they scroll near the screen.
    private func revealGraphClaim(_ app: XCUIApplication) -> Bool {
        reveal(app.descendants(matching: .any)["knowledge.graph.claim"].firstMatch, in: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<4 {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
