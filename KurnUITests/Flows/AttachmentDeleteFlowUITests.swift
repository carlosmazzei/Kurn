//
//  AttachmentDeleteFlowUITests.swift
//  KurnUITests
//
//  G1: swiping a PDF attachment to delete asks first. The confirmation is
//  attached to the root of `MeetingDetailView` rather than to a list row, so
//  it must be on screen and tappable wherever the Documents section sits in
//  the scroll — cancelling keeps the attachment, confirming removes it.
//

import XCTest

final class AttachmentDeleteFlowUITests: FlowUITestCase {

    func testSwipeDeletingAnAttachmentAsksFirstAndCancelKeepsIt() {
        openFirstMeeting()
        let recordingsTab = app.buttons["tab.recordings"]
        XCTAssertTrue(recordingsTab.waitForExistence(timeout: 10))
        recordingsTab.tap()

        let row = app.buttons["detail.attachments.row"].firstMatch
        XCTAssertTrue(scrollUntilExists(row), "Seeded attachment row missing")
        scrollIntoSafeArea(row)

        // Cancel: the dialog is fully on screen and the attachment stays.
        let delete = revealSwipeAction(on: row, identifier: "detail.attachments.delete", label: "Delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        let title = app.staticTexts["dialog.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Deleting an attachment must ask first")
        let cancel = app.buttons["dialog.secondary"]
        let confirm = app.buttons["dialog.primary"]
        XCTAssertTrue(cancel.isHittable, "Cancel must be reachable without scrolling")
        XCTAssertTrue(confirm.isHittable, "Delete must be reachable without scrolling")
        XCTAssertTrue(app.frame.contains(confirm.frame), "Dialog must sit inside the visible window")
        cancel.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists, "Cancelling must keep the attachment")

        // Confirm: the attachment is removed.
        let deleteAgain = revealSwipeAction(on: row, identifier: "detail.attachments.delete", label: "Delete")
        XCTAssertTrue(deleteAgain.waitForExistence(timeout: 5))
        deleteAgain.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Confirming must remove the attachment")
    }
}
