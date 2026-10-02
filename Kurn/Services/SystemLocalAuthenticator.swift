//
//  SystemLocalAuthenticator.swift
//  Kurn
//
//  The production `LocalAuthenticator`: `LAContext` presents Face ID, Touch ID
//  or the passcode prompt, which needs a device with an enrolled credential.
//  Everything `RecordingAccessGate` decides around it (coalescing, relock,
//  error mapping) is tested through a stub authenticator.
//

import Foundation
import LocalAuthentication

/// Default `LAContext`-backed implementation. A fresh `LAContext` is created
/// per evaluation so cached biometry state from a prior session never carries
/// over into the next.
struct SystemLocalAuthenticator: LocalAuthenticator {
    func evaluate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            throw error ?? LAError(.authenticationFailed)
        }
        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}
