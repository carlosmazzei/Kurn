//
//  SensitiveActionAuthorizerTests.swift
//  KurnTests
//
//  Re-authentication before security-sensitive changes: it never prompts
//  when the lock is already off, a device without a passcode is not refused,
//  a dismissed prompt is not an error, and every other failure refuses.
//  Also covers the lock screen's Settings escape hatch, which must only open
//  when the device cannot authenticate at all.
//

import Foundation
import KurnCore
import LocalAuthentication
import Testing
@testable import Kurn

@MainActor
struct SensitiveActionAuthorizerTests {

    private struct Unexpected: Error {}

    @Test func noLockMeansNoPrompt() async {
        let authenticator = ScriptedLocalAuthenticator(failure: Unexpected())
        let outcome = await SensitiveActionAuthorizer(authenticator: authenticator).authorize(requireAuth: false)
        #expect(outcome.isAuthorized)
        #expect(authenticator.callCount == 0)
    }

    @Test func aSuccessfulPromptAuthorizes() async {
        let authenticator = ScriptedLocalAuthenticator()
        let outcome = await SensitiveActionAuthorizer(authenticator: authenticator).authorize(requireAuth: true)
        #expect(outcome.isAuthorized)
        #expect(authenticator.callCount == 1)
    }

    @Test func aDeviceWithoutPasscodeIsNotRefused() async {
        let authorizer = SensitiveActionAuthorizer(
            authenticator: ScriptedLocalAuthenticator(failure: LAError(.passcodeNotSet))
        )
        #expect(await authorizer.authorize(requireAuth: true).isAuthorized)
    }

    @Test func dismissingThePromptIsACancelNotAnError() async {
        for code in [LAError.Code.userCancel, .appCancel, .systemCancel] {
            let authorizer = SensitiveActionAuthorizer(authenticator: ScriptedLocalAuthenticator(failure: LAError(code)))
            guard case .cancelled = await authorizer.authorize(requireAuth: true) else {
                Issue.record("expected cancelled for \(code)")
                continue
            }
        }
    }

    @Test func anyOtherFailureRefuses() async {
        for failure: Error in [LAError(.authenticationFailed), LAError(.biometryLockout), Unexpected()] {
            let authorizer = SensitiveActionAuthorizer(authenticator: ScriptedLocalAuthenticator(failure: failure))
            let outcome = await authorizer.authorize(requireAuth: true)
            #expect(!outcome.isAuthorized)
            guard case .denied = outcome else {
                Issue.record("expected denied for \(failure)")
                continue
            }
        }
    }

    // MARK: - The require-authentication toggle

    @Test func turningTheLockOnNeverPrompts() async {
        let authenticator = ScriptedLocalAuthenticator(failure: Unexpected())
        let authorizer = SensitiveActionAuthorizer(authenticator: authenticator)
        let outcome = await authorizer.authorizeRequireAuthChange(to: true, currentlyRequired: false)
        #expect(outcome.isAuthorized)
        #expect(authenticator.callCount == 0)
    }

    @Test func turningTheLockOffPrompts() async {
        let authenticator = ScriptedLocalAuthenticator(failure: LAError(.authenticationFailed))
        let authorizer = SensitiveActionAuthorizer(authenticator: authenticator)
        let outcome = await authorizer.authorizeRequireAuthChange(to: false, currentlyRequired: true)
        #expect(!outcome.isAuthorized)
        #expect(authenticator.callCount == 1)
    }

    // MARK: - perform

    @Test func performRunsTheActionOnlyWhenAuthorized() async {
        var ran = 0
        var denied: [AppError] = []

        await SensitiveActionAuthorizer(authenticator: ScriptedLocalAuthenticator())
            .perform(requireAuth: true, onDenied: { denied.append($0) }) { ran += 1 }
        #expect(ran == 1)

        await SensitiveActionAuthorizer(authenticator: ScriptedLocalAuthenticator(failure: LAError(.userCancel)))
            .perform(requireAuth: true, onDenied: { denied.append($0) }) { ran += 1 }
        #expect(ran == 1)
        #expect(denied.isEmpty)

        await SensitiveActionAuthorizer(authenticator: ScriptedLocalAuthenticator(failure: LAError(.authenticationFailed)))
            .perform(requireAuth: true, onDenied: { denied.append($0) }) { ran += 1 }
        #expect(ran == 1)
        #expect(denied.count == 1)
    }

    // MARK: - Lock screen escape hatch

    @Test func theEscapeHatchStaysClosedUntilAuthenticationIsImpossible() async {
        let fresh = RecordingAccessGate(authenticator: ScriptedLocalAuthenticator())
        #expect(!fresh.offersSettingsEscapeHatch)

        let cancelled = RecordingAccessGate(authenticator: ScriptedLocalAuthenticator(failure: LAError(.userCancel)))
        await cancelled.authenticate()
        #expect(!cancelled.offersSettingsEscapeHatch)

        let failed = RecordingAccessGate(authenticator: ScriptedLocalAuthenticator(failure: LAError(.authenticationFailed)))
        await failed.authenticate()
        #expect(!failed.offersSettingsEscapeHatch)

        let noPasscode = RecordingAccessGate(authenticator: ScriptedLocalAuthenticator(failure: LAError(.passcodeNotSet)))
        await noPasscode.authenticate()
        #expect(noPasscode.offersSettingsEscapeHatch)

        noPasscode.lock()
        #expect(!noPasscode.offersSettingsEscapeHatch)
    }
}
