//
//  BulkSelectionFlowUITests.swift
//  KurnUITests
//
//  The meetings list's selection mode against the seeded in-memory store:
//  picking meetings updates the title count, Export opens the bulk export
//  sheet with one file per meeting or a single file, and Delete asks first —
//  cancelling keeps everything, confirming removes exactly the picked
//  meetings and leaves selection mode. The rules behind each step are unit
//  tested in `MeetingListSelectionTests` and `MeetingBulkExportTests`; this
//  covers what only the real screens can: that the toolbar, the cards and the
//  sheet are wired to them.
//

import XCTest

final class BulkSelectionFlowUITests: FlowUITestCase {

    private var cards: XCUIElementQuery { app.buttons.matching(identifier: "meetingCard") }

    /// Enters selection mode from the toolbar and waits for its chrome.
    private func beginSelecting() {
        let select = app.buttons["meetings.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        XCTAssertTrue(tap(select, until: app.buttons["meetings.selection.done"]), "Selection mode did not start")
    }

    /// The navigation title in selection mode ("Selected: N", en).
    private func selectedTitle(_ count: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Selected: \(count)"))
            .firstMatch
    }

    /// Picks the first `count` visible meetings, returning their card labels.
    @discardableResult
    private func pickFirst(_ count: Int) -> [String] {
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(cards.count, count, "Seed has fewer meetings than the flow needs")
        var labels: [String] = []
        for index in 0..<count {
            let card = cards.element(boundBy: index)
            labels.append(card.label)
            card.tap()
            XCTAssertTrue(selectedTitle(index + 1).waitForExistence(timeout: 5), "Pick \(index + 1) not counted")
        }
        return labels
    }

    func testPickingMeetingsOpensBulkExportWithOneFileEachOrOneFile() {
        beginSelecting()

        let export = app.buttons["meetings.selection.export"]
        XCTAssertTrue(selectedTitle(0).waitForExistence(timeout: 5))
        XCTAssertFalse(export.isEnabled, "Export must wait for a pick")

        pickFirst(2)
        XCTAssertTrue(export.isEnabled)

        let share = app.buttons["bulk_export.share_button"]
        XCTAssertTrue(tap(export, until: share, timeout: 10), "Bulk export sheet did not open")
        XCTAssertTrue(share.isEnabled, "Seeded meetings have summaries and transcripts to export")
        XCTAssertTrue(share.label.hasSuffix("(2)"), "One file per meeting by default, got \(share.label)")

        // Segmented-picker segments carry no identifiers of their own;
        // `bulk_export.grouping.single` is the en string.
        let singleFile = app.buttons["Single file"]
        XCTAssertTrue(singleFile.waitForExistence(timeout: 5))
        // At the sheet's medium height the grouping row sits partly under the
        // share bar laid over the form, where a tap reaches the bar instead.
        // Swipe until the segment clears it (the form scrolls, or the sheet
        // grows to its large height — either uncovers it).
        let barTop = app.buttons["bulk_export.format_picker"]
        for _ in 0..<3 where singleFile.frame.maxY > barTop.frame.minY - 8 {
            app.swipeUp()
        }
        XCTAssertLessThan(singleFile.frame.maxY, barTop.frame.minY, "Grouping segment is still under the share bar")
        singleFile.tap()
        XCTAssertTrue(waitUntil(share, "label ENDSWITH '(1)'"), "Single file should export one file, got \(share.label)")

        app.buttons["bulk_export.cancel"].tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 5), "Bulk export sheet did not dismiss")

        // Cancelling the export keeps the selection; Done leaves selection mode.
        XCTAssertTrue(selectedTitle(2).exists)
        XCTAssertTrue(tap(app.buttons["meetings.selection.done"], until: app.buttons["meetings.select"]))
    }

    func testBulkDeleteAsksFirstAndRemovesOnlyThePickedMeetings() {
        beginSelecting()
        let picked = pickFirst(2)

        let delete = app.buttons["meetings.selection.delete"]
        let dialogTitle = app.staticTexts["dialog.title"]
        XCTAssertTrue(tap(delete, until: dialogTitle), "Bulk delete must confirm first")
        app.buttons["dialog.secondary"].tap()
        XCTAssertTrue(dialogTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(selectedTitle(2).exists, "Cancelling the delete must keep the selection")
        for label in picked {
            XCTAssertTrue(cards.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
        }

        XCTAssertTrue(tap(delete, until: dialogTitle))
        app.buttons["dialog.primary"].tap()

        // A confirmed delete leaves selection mode and the picked cards.
        XCTAssertTrue(app.buttons["meetings.select"].waitForExistence(timeout: 10), "Selection mode did not end")
        for label in picked {
            let card = cards.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(card.waitForNonExistence(timeout: 5), "Deleted meeting is still listed")
        }
        XCTAssertTrue(cards.firstMatch.exists, "Meetings that were not picked must stay")
    }
}
