//
//  RecordingAccessGate.swift
//  Kurn
//
//  Per-session biometric / passcode gate guarding the recordings UI. The user
//  authenticates once per foreground session; the gate is re-locked when the
//  app moves to the background so a borrowed-unlocked device cannot expose
//  meeting audio.
//

import Foundation
import LocalAuthentication
import Observation

/// Abstraction over `LAContext.evaluatePolicy` so unit tests can inject a stub
/// without invoking the real biometrics subsystem.
protocol LocalAuthenticator: Sendable {
    /// Evaluate device-owner authentication (biometrics, falling back to
    /// passcode). Returns successfully or throws an `Error` describing the
    /// failure. The implementation must present the system UI when needed.
    func evaluate(reason: String) async throws
}

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

@MainActor
@Observable
final class RecordingAccessGate {
    /// True once the user has authenticated in this foreground session.
    private(set) var isUnlocked: Bool = false
    /// Set when the most recent authentication attempt failed, so the lock
    /// view can show the reason and a retry button.
    private(set) var lastError: AppError?

    @ObservationIgnored private let authenticator: LocalAuthenticator
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(authenticator: LocalAuthenticator = SystemLocalAuthenticator()) {
        self.authenticator = authenticator
    }

    /// Present the system biometric / passcode prompt. Multiple concurrent
    /// callers (e.g. a list and detail view both appearing) coalesce onto a
    /// single in-flight evaluation.
    func authenticate() async {
        if isUnlocked { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            await self.performAuthentication()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Reset the unlocked state. Called from the scene-phase observer when the
    /// app enters the background.
    func lock() {
        isUnlocked = false
        lastError = nil
        inFlight?.cancel()
        inFlight = nil
    }

    private func performAuthentication() async {
        let reason = NSLocalizedString(
            "recordings.unlock_reason",
            comment: "Reason shown in the Face ID/passcode prompt"
        )
        do {
            try await authenticator.evaluate(reason: reason)
            isUnlocked = true
            lastError = nil
        } catch {
            isUnlocked = false
            lastError = .authenticationFailed(error.localizedDescription)
        }
    }
}
