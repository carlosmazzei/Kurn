//
//  SettingsFlowUITests.swift
//  KurnUITests
//
//  Settings drill-down flows: Providers (the on-device default with no API key
//  configured), Transcription (choosing an engine that needs a model download
//  must ask first and leave the selection untouched when declined), Storage
//  and Health & Recovery (a clean seeded store reports nothing to recover).
//
//  The transcription flow is the one that exercises a resilience rule rather
//  than navigation: `ModelDownloadController.selectTranscriptionEngine` never
//  starts a download without consent, so cancelling the dialog is the "switch
//  engine without download" path — the engine stays on Apple Speech and no
//  network is touched.
//

import XCTest

final class SettingsFlowUITests: FlowUITestCase {

    // MARK: - Providers

    func testProvidersListsBuiltInProvidersAndAddAction() {
        openSettingsScreen("settings.link.providers")

        XCTAssertTrue(anyElement("settings.providers.form").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.providers.row.apple-on-device"].exists)
        XCTAssertTrue(app.buttons["settings.providers.row.openAI"].exists)
        XCTAssertTrue(app.buttons["settings.providers.add"].exists)
    }

    func testOpeningAProviderPushesItsEditor() {
        openSettingsScreen("settings.link.providers")

        let row = app.buttons["settings.providers.row.openAI"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(anyElement("settings.providers.form").waitForNonExistence(timeout: 5))
        goBack()
        XCTAssertTrue(anyElement("settings.providers.form").waitForExistence(timeout: 5))
    }

    // MARK: - Transcription

    func testDecliningAModelDownloadKeepsTheCurrentEngine() {
        openSettingsScreen("settings.link.transcription")

        let picker = app.buttons["settings.transcription.engine"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let before = pickerValue(picker)
        XCTAssertTrue(before.contains("Apple Speech"), "Fresh install should default to Apple Speech, got \(before)")

        picker.tap()
        // Menu-picker options carry no identifiers of their own; the en
        // `transcription.fluid_parakeet` string is the only stable handle.
        let parakeet = app.buttons["FluidAudio (multilingual)"]
        XCTAssertTrue(parakeet.waitForExistence(timeout: 5))
        parakeet.tap()

        let dialogTitle = app.staticTexts["dialog.title"]
        XCTAssertTrue(dialogTitle.waitForExistence(timeout: 5), "Consent dialog must precede any download")
        app.buttons["dialog.secondary"].tap()
        XCTAssertTrue(dialogTitle.waitForNonExistence(timeout: 5))

        XCTAssertEqual(pickerValue(picker), before)
    }

    // MARK: - Storage / Health & Recovery

    func testStorageScreenRenders() {
        openSettingsScreen("settings.link.storage")
        XCTAssertTrue(anyElement("settings.storage.form").waitForExistence(timeout: 10))
    }

    func testHealthRecoveryRendersAllClearOrRecentFailures() {
        openSettingsScreen("settings.link.health")

        XCTAssertTrue(anyElement("health.list").waitForExistence(timeout: 10))

        // The seeded store has nothing to recover, but the reliability event
        // log is real on-disk state shared by every suite in this simulator
        // (`ModelStoreRecoveryUITests` deliberately records boot failures),
        // so either the all-clear row or the recent-failures section is the
        // correct rendering — never an empty list.
        let allClear = anyElement("health.all_clear")
        let failures = app.buttons["health.view_all_events"]
        let rendered = NSPredicate { _, _ in allClear.exists || failures.exists }
        let expectation = XCTNSPredicateExpectation(predicate: rendered, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }

    private func pickerValue(_ picker: XCUIElement) -> String {
        (picker.value as? String) ?? picker.label
    }
}
