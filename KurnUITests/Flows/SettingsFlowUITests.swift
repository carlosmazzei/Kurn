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

        XCTAssertTrue(anyElement("settings.providers.editor").waitForExistence(timeout: 5))
        goBack(to: "AI Providers")
        XCTAssertTrue(anyElement("settings.providers.form").waitForExistence(timeout: 5))
    }

    // MARK: - Transcription

    func testDecliningAModelDownloadKeepsTheCurrentEngine() {
        openSettingsScreen("settings.link.transcription")

        let picker = anyElement("settings.transcription.engine")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let before = pickerValue(picker)
        XCTAssertTrue(before.contains("Apple Speech"), "Fresh install should default to Apple Speech, got \(before)")

        picker.tap()
        // Menu-picker options carry no identifiers of their own; the en
        // `transcription.fluid_parakeet` string is the only stable handle.
        let parakeet = app.buttons["FluidAudio (on-device)"]
        XCTAssertTrue(parakeet.waitForExistence(timeout: 5))
        parakeet.tap()

        let dialogTitle = app.staticTexts["dialog.title"]
        XCTAssertTrue(dialogTitle.waitForExistence(timeout: 5), "Consent dialog must precede any download")
        app.buttons["dialog.secondary"].tap()
        XCTAssertTrue(dialogTitle.waitForNonExistence(timeout: 5))

        XCTAssertEqual(pickerValue(picker), before)
    }

    func testDecliningNemotronDiarizationKeepsPyannoteDefaults() throws {
        openSettingsScreen("settings.link.transcription")

        let picker = anyElement("settings.fluid_audio.diarization_model")
        XCTAssertTrue(scrollUntilExists(picker), "The default FluidAudio diarization model picker is missing")
        scrollIntoSafeArea(picker)
        let before = pickerValue(picker)
        XCTAssertTrue(before.contains("Pyannote"), "Fresh install should default to Pyannote, got \(before)")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])

        let nemotron = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nemotron 3")).firstMatch
        XCTAssertTrue(tap(picker, until: nemotron), "The Nemotron 3 diarization option is missing")
        XCTAssertTrue(nemotron.isEnabled)
        nemotron.tap()
        cancelModelConsent(named: "Nemotron 3")

        XCTAssertEqual(pickerValue(picker), before)
        XCTAssertTrue(picker.isEnabled)
        let batch = anyElement("settings.fluid_audio.segmentation_batch")
        XCTAssertTrue(scrollUntilExists(batch), "Cancelling must preserve Pyannote's segmentation controls")
        let batchValue = pickerValue(batch)
        XCTAssertTrue(batchValue.contains("32"), "The preserved batch default should be 32, got \(batchValue)")
        XCTAssertTrue(batch.isEnabled)

        let speakerCount = app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", "Number of Speakers")).firstMatch
        XCTAssertTrue(scrollUntilExists(speakerCount), "Cancelling must preserve Pyannote's pinned speaker-count control")
        let speakerValue = "\(speakerCount.label) \(pickerValue(speakerCount))"
        XCTAssertTrue(speakerValue.contains("Auto"), "The pinned speaker-count default should remain Auto, got \(speakerValue)")
        XCTAssertTrue(speakerCount.isEnabled)
    }

    func testDecliningUnifiedLiveModelKeepsAutomaticAndPreviewOff() throws {
        openSettingsScreen("settings.link.recording")

        let preview = app.switches["Live Transcription Preview"]
        XCTAssertTrue(scrollUntilExists(preview))
        XCTAssertEqual(preview.value as? String, "0", "Fresh install should leave live transcription preview off")

        let picker = anyElement("settings.fluid_audio.live_model")
        XCTAssertTrue(scrollUntilExists(picker), "The live preview model picker is missing")
        scrollIntoSafeArea(picker)
        let before = pickerValue(picker)
        XCTAssertTrue(before.contains("Automatic"), "Fresh install should default to Automatic, got \(before)")
        XCTAssertTrue(before.contains("Parakeet EOU / Nemotron Multilingual"))

        let unified = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nemotron Unified 0.6B")).firstMatch
        XCTAssertTrue(tap(picker, until: unified), "The Nemotron Unified live-preview option is missing")
        XCTAssertTrue(unified.isEnabled)
        unified.tap()
        cancelModelConsent(named: "Nemotron Unified 0.6B")

        XCTAssertEqual(pickerValue(picker), before)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertEqual(preview.value as? String, "0", "Cancelling model consent must not enable live preview")
        XCTAssertTrue(preview.isEnabled)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
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
        // Identifiers set on a `Label` or `NavigationLink` inside a `List`
        // row are not always surfaced by XCUITest, so the visible en strings
        // are accepted as the second handle.
        // The events link sits below up to 100 per-event rows, so the first
        // failure row is the reliable handle (its log line starts with
        // "<operation>: failed").
        let allClear = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "health.all_clear", "Nothing needs attention")
        ).firstMatch
        let failures = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@ OR label CONTAINS %@ OR label == %@",
                ["health.recent_failure", "health.view_all_events"], ": failed ", "View All Reliability Events"
            )
        ).firstMatch
        if allClear.waitForExistence(timeout: 5) { return }
        XCTAssertTrue(scrollUntilExists(failures), "Health & Recovery rendered neither all-clear nor recent failures")
    }

    private func cancelModelConsent(named modelName: String) {
        let title = app.staticTexts["dialog.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Consent must precede any model download")
        XCTAssertEqual(title.label, "One-Time Model Download")
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Download \(modelName) (")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Generic consent must name \(modelName)")
        XCTAssertTrue(message.label.contains("approximately"), "Consent must disclose the approximate download size")
        let cancel = app.buttons["dialog.secondary"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertEqual(cancel.label, "Cancel")
        cancel.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }
}
