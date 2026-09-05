//
//  LibraryFlowUITests.swift
//  KurnUITests
//
//  Tag and Folder CRUD through the real screens against the seeded in-memory
//  store: create → row appears; swipe delete → the shared `kurnDialog`
//  confirmation → row gone. Names carry a per-launch suffix so a flow never
//  collides with the seeded "Roadmap"/"Product" entries or with itself when
//  the flake-rate lane repeats the run.
//

import XCTest

final class LibraryFlowUITests: FlowUITestCase {

    // MARK: - Tags

    func testCreateAndDeleteATag() {
        openSettingsScreen("settings.link.tags")

        let manage = app.buttons["settings.tags.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()

        let name = "UITest-\(UUID().uuidString.prefix(6))"
        let field = app.textFields["tags.new_name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)

        let add = app.buttons["tags.add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()

        let row = anyElement("tags.row.\(name)")
        XCTAssertTrue(scrollUntilExists(row), "Created tag row did not appear")

        row.swipeLeft()
        let delete = swipeActionButton(identifier: "tags.row.delete", label: "Delete Tag")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        XCTAssertTrue(app.staticTexts["dialog.title"].waitForExistence(timeout: 5))
        app.buttons["dialog.primary"].tap()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Deleted tag row is still listed")
    }

    func testAddIsDisabledForABlankTagName() {
        openSettingsScreen("settings.link.tags")
        app.buttons["settings.tags.manage"].tap()

        let add = app.buttons["tags.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(add.isEnabled)
    }

    // MARK: - Folders

    func testCreateAndDeleteAFolder() {
        let library = app.buttons["meetings.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()

        let newFolder = app.buttons["folders.new"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10))
        newFolder.tap()

        let name = "UIFolder-\(UUID().uuidString.prefix(6))"
        let field = app.textFields["folder.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let save = app.buttons["folder.save"]
        XCTAssertFalse(save.isEnabled, "Save must stay disabled until a name is typed")

        field.tap()
        field.typeText(name)
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(anyElement("folder.name").waitForNonExistence(timeout: 5), "Folder form did not dismiss")

        // New folders sort last by creation date, below the seeded ones.
        let row = app.buttons["folders.row.\(name)"]
        XCTAssertTrue(scrollUntilExists(row), "Created folder row did not appear")

        row.swipeLeft()
        let delete = swipeActionButton(identifier: "folders.row.delete", label: "Delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        XCTAssertTrue(app.staticTexts["dialog.title"].waitForExistence(timeout: 5))
        app.buttons["dialog.primary"].tap()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Deleted folder row is still listed")
    }

    func testSeededFoldersAreListed() {
        app.buttons["meetings.library"].tap()
        XCTAssertTrue(app.buttons["folders.row.Product"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["folders.row.Design"].exists)
    }
}
