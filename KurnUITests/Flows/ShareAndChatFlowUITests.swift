//
//  ShareAndChatFlowUITests.swift
//  KurnUITests
//
//  Share sheet up to the Obsidian format choice (stopping short of the system
//  activity sheet, which is not this app's UI), and the Ask/Chat entry point
//  with no provider configured — a seeded launch has no API key and no
//  semantic index, so the chat must land on its empty state and keep the
//  composer disabled rather than attempt a network call.
//

import XCTest

final class ShareAndChatFlowUITests: FlowUITestCase {

    // MARK: - Share

    func testShareSheetSwitchesToObsidianFormat() {
        openFirstMeeting()
        openShareSheet()

        let explanation = app.staticTexts["share.format_explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        let standardExplanation = explanation.label

        let picker = app.buttons["share.format_picker"]
        XCTAssertTrue(picker.exists)
        picker.tap()
        // Menu-picker options carry no identifiers; `share.format.obsidian`
        // is the en string.
        let obsidian = app.buttons["Obsidian"]
        XCTAssertTrue(obsidian.waitForExistence(timeout: 5))
        obsidian.tap()

        let switched = NSPredicate { _, _ in explanation.label != standardExplanation }
        let expectation = XCTNSPredicateExpectation(predicate: switched, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(explanation.label.localizedCaseInsensitiveContains("frontmatter"))

        XCTAssertTrue(app.buttons["share.share_button"].isEnabled, "Seeded meeting has transcripts to share")
        app.buttons["share.cancel"].tap()
        XCTAssertTrue(explanation.waitForNonExistence(timeout: 5))
    }

    func testShareSheetPreselectsTranscribedRecordings() {
        openFirstMeeting()
        openShareSheet()

        let share = app.buttons["share.share_button"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertTrue(share.isEnabled)
        XCTAssertTrue(app.buttons["share.copy_all"].isEnabled)
    }

    private func openShareSheet() {
        let more = app.buttons["detail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let share = app.buttons["detail.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
    }

    // MARK: - Chat

    func testAskWithoutAProviderShowsAnEmptyStateAndDisablesTheComposer() {
        let ask = app.buttons["meetings.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()

        let emptyState = anyElement("chat.empty_state")
        let disabledState = anyElement("chat.disabled_state")
        let rendered = NSPredicate { _, _ in emptyState.exists || disabledState.exists }
        let expectation = XCTNSPredicateExpectation(predicate: rendered, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "Composer must be disabled with nothing to chat about")
        let input = anyElement("chat.input")
        if input.exists {
            XCTAssertFalse(input.isEnabled)
        }
    }
}
