//
//  CaptureInputSelectionTests.swift
//  KurnTests
//
//  `CaptureInputSelection` decides both which input a recording uses and
//  whether the session may drop its output route. The built-in mic must
//  resolve to `.record` (no output), or a connected hearing aid is switched
//  into its streaming program for the whole meeting.
//

import AVFoundation
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

struct CapturePolarPatternTests {
    @Test func wholeRoomPrefersOmnidirectional() {
        #expect(CaptureInputSelection.preferredPolarPatterns(for: .wholeRoom) == [.omnidirectional, .subcardioid])
    }

    @Test func focusSpeakerPrefersCardioid() {
        #expect(CaptureInputSelection.preferredPolarPatterns(for: .focusSpeaker) == [.cardioid, .subcardioid])
    }
}

struct SessionActivationRetryTests {
    private struct Transient: Error {}

    @Test func succeedsFirstTimeWithoutRetrying() async throws {
        var calls = 0
        var retries: [Int] = []
        try await SessionActivationRetry.run(delayNanoseconds: 0) {
            calls += 1
        } onRetry: { attempt, _ in
            retries.append(attempt)
        }
        #expect(calls == 1)
        #expect(retries.isEmpty)
    }

    @Test func ridesOutATransientFailure() async throws {
        var calls = 0
        var retries: [Int] = []
        try await SessionActivationRetry.run(delayNanoseconds: 0) {
            calls += 1
            if calls < 3 { throw Transient() }
        } onRetry: { attempt, _ in
            retries.append(attempt)
        }
        #expect(calls == 3)
        #expect(retries == [1, 2])
    }

    @Test func throwsTheLastErrorOnceAttemptsRunOut() async {
        var calls = 0
        await #expect(throws: Transient.self) {
            try await SessionActivationRetry.run(attempts: 2, delayNanoseconds: 0) {
                calls += 1
                throw Transient()
            }
        }
        #expect(calls == 2)
    }

    @Test func atLeastOneAttemptIsMade() async {
        var calls = 0
        await #expect(throws: Transient.self) {
            try await SessionActivationRetry.run(attempts: 0, delayNanoseconds: 0) {
                calls += 1
                throw Transient()
            }
        }
        #expect(calls == 1)
    }
}
