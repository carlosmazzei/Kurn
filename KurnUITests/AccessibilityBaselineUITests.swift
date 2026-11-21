//
//  AccessibilityBaselineUITests.swift
//  KurnUITests
//
//  U0.1–U0.3: Widened accessibility audit across all six audit categories
//  (`.contrast`, `.dynamicType`, `.hitRegion`, `.sufficientElementDescription`,
//  `.textClipped`, `.trait`) at default text size and at AX5
//  (`accessibilityExtraExtraExtraLarge`), covering the Meetings List, all
//  five Meeting Detail tabs (including Knowledge), Settings, RecorderView,
//  FolderFormView, the Knowledge entity page with a seeded narrative ("Notes"),
//  and the Knowledge reader toolbar with export enabled.
//
//  Runs outside the required PR check (`swift.yml` and `ui-flake-rate` skip
//  this class; `reliability-hardening.yml` runs it in its own job) until its
//  findings are fixed and U5 moves it into the required shards.
//

import XCTest

@MainActor
final class AccessibilityBaselineUITests: XCTestCase {
    private static let auditTypes: XCUIAccessibilityAuditType = [
        .contrast,
        .dynamicType,
        .hitRegion,
        .sufficientElementDescription,
        .textClipped,
        .trait
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(
        ax5: Bool = false,
        knowledge: Bool = false,
        prototype: Bool = false,
        narrative: Bool = false,
        exportEnabled: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "UI-Testing-Screenshots",
            "UI-Testing-DisableAnimations",
            "-settings.semanticSearchEnabled", "NO",
            "-settings.meetingsSortOrder", "dateNewest",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        if ax5 {
            app.launchArguments += [
                "UI-Testing-AX5",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        if knowledge {
            app.launchArguments += [
                "UI-Testing-KnowledgeFixture",
                "-settings.knowledgeEnabled", "YES"
            ]
        }
        if prototype {
            app.launchArguments += ["UI-Testing-KnowledgeNavigationPrototype"]
        }
        if narrative {
            app.launchArguments += ["UI-Testing-KnowledgeNarrativeFixture"]
        }
        if exportEnabled {
            app.launchArguments += ["-settings.knowledgeExportEnabled", "YES"]
        }
        app.launch()
        return app
    }

    private func audit(_ app: XCUIApplication, screen: String, sizeLabel: String) {
        XCTContext.runActivity(named: "Audit \(screen) (\(sizeLabel))") { _ in
            do {
                try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                    XCTFail("[\(screen) | \(sizeLabel)] [\(issue.auditType)] \(issue.compactDescription) — \(issue.detailedDescription) | element=\(String(describing: issue.element?.debugDescription.prefix(240)))")
                    return true
                }
            } catch {
                XCTFail("[\(screen) | \(sizeLabel)] Audit threw error: \(error)")
            }
        }
    }

    // MARK: - Core Screens (Default & AX5)

    func testCoreScreensDefaultSize() throws {
        try runCoreScreens(ax5: false)
    }

    func testCoreScreensAX5() throws {
        try runCoreScreens(ax5: true)
    }

    private func runCoreScreens(ax5: Bool) throws {
        let sizeLabel = ax5 ? "AX5" : "Default"
        let app = launch(ax5: ax5)

        // 1. Meetings List
        XCTAssertTrue(app.buttons["meetingCard"].firstMatch.waitForExistence(timeout: 10))
        audit(app, screen: "MeetingsList", sizeLabel: sizeLabel)

        // 2. FolderFormView (via Library -> New Folder)
        let library = app.buttons["meetings.library"]
        if library.waitForExistence(timeout: 5) {
            library.tap()
            let newFolder = app.buttons["folders.new"]
            for _ in 0..<4 where !newFolder.exists || !newFolder.isHittable {
                app.swipeUp()
            }
            if newFolder.waitForExistence(timeout: 10) {
                newFolder.tap()
                XCTAssertTrue(app.textFields["folder.name"].waitForExistence(timeout: 10))
                audit(app, screen: "FolderFormView", sizeLabel: sizeLabel)
                if app.buttons["folder.cancel"].exists {
                    app.buttons["folder.cancel"].tap()
                }
            }
            let done = app.navigationBars.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 5) {
                done.tap()
            }
        }

        // 3. Settings Hub
        let settings = app.buttons["nav.settings"]
        if settings.waitForExistence(timeout: 10) {
            settings.tap()
            XCTAssertTrue(app.buttons["settings.link.providers"].waitForExistence(timeout: 10))
            audit(app, screen: "SettingsView", sizeLabel: sizeLabel)
            let done = app.navigationBars.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 5) {
                done.tap()
            }
        }

        // 4. Meeting Detail Tabs (Recordings, Transcript, Summary, Chat)
        openFirstMeeting(app)
        for tab in ["recordings", "transcript", "summary", "chat"] {
            let button = app.buttons["tab.\(tab)"]
            if button.waitForExistence(timeout: 10) {
                button.tap()
                audit(app, screen: "MeetingDetail.\(tab)", sizeLabel: sizeLabel)
            }
        }

        // 5. RecorderView (audited last so no active recording session or mini
        // bar pollutes Settings or MeetingDetail, and returning to the list is
        // not required after the audit).
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        let record = app.buttons["meetings.record"]
        if record.waitForExistence(timeout: 10) {
            record.tap()
            let minimize = app.buttons["recorder.minimize"]
            if minimize.waitForExistence(timeout: 10) {
                audit(app, screen: "RecorderView", sizeLabel: sizeLabel)
            }
        }
    }

    // MARK: - Knowledge Screens (Default & AX5)

    func testKnowledgeScreensDefaultSize() throws {
        try runKnowledgeScreens(ax5: false)
    }

    func testKnowledgeScreensAX5() throws {
        try runKnowledgeScreens(ax5: true)
    }

    private func runKnowledgeScreens(ax5: Bool) throws {
        let sizeLabel = ax5 ? "AX5" : "Default"
        let app = launch(ax5: ax5, knowledge: true, prototype: true, narrative: true, exportEnabled: true)

        // 1. Knowledge Browser Home (with export button visible in reader toolbar)
        let entity = app.buttons["knowledge.browser.entity"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["knowledge.browser.export"].exists)
        audit(app, screen: "KnowledgeHome+ExportToolbar", sizeLabel: sizeLabel)

        // 2. Entity Page with seeded narrative ("Notes")
        entity.tap()
        let narrative = app.descendants(matching: .any)["knowledge.browser.narrative"].firstMatch
        XCTAssertTrue(narrative.waitForExistence(timeout: 10))
        audit(app, screen: "KnowledgeEntityPage+Narrative", sizeLabel: sizeLabel)

        // Pop back to Knowledge Home so its Done button is visible, then close the sheet
        let back = readerBackButton(app)
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        let done = app.navigationBars.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 10) {
            done.tap()
        }
        XCTAssertTrue(app.buttons["root.destination.meetings"].waitForExistence(timeout: 10))
        audit(app, screen: "MeetingsList+KnowledgeOn", sizeLabel: sizeLabel)

        openFirstMeeting(app)
        let knowledgeTab = app.buttons["tab.knowledge"]
        if knowledgeTab.waitForExistence(timeout: 10) {
            knowledgeTab.tap()
            let quote = app.staticTexts["knowledge.quote"].firstMatch
            _ = quote.waitForExistence(timeout: 10)
            audit(app, screen: "MeetingDetail.knowledge", sizeLabel: sizeLabel)
        }
    }

    private func readerBackButton(_ app: XCUIApplication) -> XCUIElement {
        let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
        let back = bar.buttons["BackButton"]
        return back.exists ? back : bar.buttons.element(boundBy: 0)
    }

    private func openFirstMeeting(_ app: XCUIApplication) {
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
