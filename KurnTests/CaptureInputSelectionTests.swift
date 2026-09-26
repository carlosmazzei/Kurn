//
//  CaptureInputSelectionTests.swift
//  KurnTests
//
//  `CaptureInputSelection` decides both which input a recording uses and
//  whether the session may drop its output route. The built-in mic must
//  resolve to `.record` (no output), or a connected hearing aid is switched
//  into its streaming program for the whole meeting.
//

import Testing
@testable import Kurn

struct CaptureInputSelectionTests {
    private let builtIn = CaptureInputSelection.Input(uid: "Built-In Microphone", isBuiltIn: true)
    private let hearingAid = CaptureInputSelection.Input(uid: "hearing-aid", isBuiltIn: false)

    @Test func explicitBuiltInChoiceUsesRecordOnlySession() {
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn, hearingAid],
            forceBuiltIn: false,
            preferredInputUID: builtIn.uid
        )
        #expect(selection == .builtIn(uid: builtIn.uid))
        #expect(!selection.needsPlayAndRecord)
    }

    @Test func explicitExternalChoiceKeepsPlayAndRecord() {
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn, hearingAid],
            forceBuiltIn: true,
            preferredInputUID: hearingAid.uid
        )
        #expect(selection == .external(uid: hearingAid.uid))
        #expect(selection.needsPlayAndRecord)
    }

    @Test func forcedBuiltInWinsOverConnectedAccessory() {
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn, hearingAid],
            forceBuiltIn: true,
            preferredInputUID: nil
        )
        #expect(selection == .builtIn(uid: builtIn.uid))
    }

    @Test func outputOnlyHearingDeviceStillResolvesToBuiltIn() {
        // Hearing aids that expose no microphone never appear as an input.
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn],
            forceBuiltIn: false,
            preferredInputUID: nil
        )
        #expect(selection == .builtIn(uid: builtIn.uid))
        #expect(!selection.needsPlayAndRecord)
    }

    @Test func connectedAccessoryWithoutPreferenceDefersToSystem() {
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn, hearingAid],
            forceBuiltIn: false,
            preferredInputUID: nil
        )
        #expect(selection == .systemDefault)
        #expect(selection.needsPlayAndRecord)
    }

    @Test func staleUIDFallsBackToTheRegularRules() {
        let selection = CaptureInputSelection.resolve(
            inputs: [builtIn],
            forceBuiltIn: false,
            preferredInputUID: "gone"
        )
        #expect(selection == .builtIn(uid: builtIn.uid))
    }
}
