//
//  SensitiveActionAuthorizer.swift
//  Kurn
//
//  Re-authentication for actions that weaken or bypass the recordings lock, or
//  that decide where meeting content is sent: turning the lock off, saving a
//  provider's key or base URL, erasing the library, and the store-recovery
//  actions that read every meeting while the normal lock is not yet in place.
//
//  Being past the lock once is not enough for these. `RecordingAccessGate`
//  unlocks for a whole foreground session, so anyone holding the device
//  afterwards could otherwise turn protection off for good, or point future
//  transcriptions at a server of their choosing, with one tap.
//
//  Deliberately separate from the gate's session state: authorizing one of
//  these actions must not unlock the library, and a failure here must not
//  re-lock it.
//

import Foundation
import KurnCore
import LocalAuthentication

enum SensitiveActionAuthorization: Sendable {
    case authorized
    /// The user dismissed the prompt. Not an error worth an alert.
    case cancelled
    case denied(AppError)

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }
}

struct SensitiveActionAuthorizer: Sendable {
    private let authenticator: LocalAuthenticator

    init(authenticator: LocalAuthenticator = SystemLocalAuthenticator()) {
        self.authenticator = authenticator
    }

    /// `requireAuth` is `AppSettings.requireAuthForRecordings`: when the user
    /// has already turned the lock off there is nothing left to protect, and
    /// prompting would only add friction.
    func authorize(requireAuth: Bool) async -> SensitiveActionAuthorization {
        guard requireAuth else { return .authorized }
        let reason = NSLocalizedString(
            "auth.sensitive_change_reason",
            comment: "Reason shown in the Face ID/passcode prompt before a security-sensitive change"
        )
        do {
            try await authenticator.evaluate(reason: reason)
            return .authorized
        } catch {
            return Self.outcome(for: error)
        }
    }

    /// Turning the recordings lock *on* only adds protection and never asks;
    /// turning it *off* is the one change this type exists for.
    func authorizeRequireAuthChange(
        to newValue: Bool,
        currentlyRequired: Bool
    ) async -> SensitiveActionAuthorization {
        guard !newValue else { return .authorized }
        return await authorize(requireAuth: currentlyRequired)
    }

    /// Runs `action` only once authorized. A refusal is handed to `onDenied`
    /// (for the screen's error dialog); a dismissed prompt does nothing.
    @MainActor
    func perform(
        requireAuth: Bool,
        onDenied: (AppError) -> Void,
        _ action: () -> Void
    ) async {
        switch await authorize(requireAuth: requireAuth) {
        case .authorized: action()
        case .cancelled: break
        case .denied(let error): onDenied(error)
        }
    }

    /// A device with no passcode cannot authenticate anyone, so it offers no
    /// protection this check could preserve — refusing would only strand the
    /// owner, the same reasoning as the lock screen's Settings escape hatch.
    /// Everything else that is not a success is a refusal.
    static func outcome(for error: Error) -> SensitiveActionAuthorization {
        if let laError = error as? LAError {
            switch laError.code {
            case .passcodeNotSet:
                return .authorized
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            default:
                break
            }
        }
        return .denied(RecordingAccessGate.appError(for: error))
    }
}
