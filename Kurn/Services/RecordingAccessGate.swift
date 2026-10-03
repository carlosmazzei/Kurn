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
import KurnCore
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

@MainActor
@Observable
final class RecordingAccessGate {
    /// True once the user has authenticated in this foreground session.
    private(set) var isUnlocked: Bool = false
    /// Set when the most recent authentication attempt failed, so the lock
    /// view can show the reason and a retry button.
    private(set) var lastError: AppError?

    /// True while a biometric/passcode evaluation is in progress. The system
    /// prompt itself (especially the passcode fallback screen) can transiently
    /// flip `scenePhase` to `.inactive`, so callers reacting to scene-phase
    /// changes should not lock (and cancel this task) while this is true.
    var isAuthenticating: Bool { inFlight != nil }

    /// Whether the lock screen may offer its way into Settings. Only when the
    /// device cannot authenticate anyone at all (no passcode): otherwise that
    /// route would let whoever holds the device switch the lock off without
    /// ever proving who they are.
    var offersSettingsEscapeHatch: Bool {
        if case .authenticationNotAvailable = lastError { return true }
        return false
    }

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
    /// app enters the background. No-ops while a biometric/passcode
    /// evaluation is in flight — the class that owns `inFlight` is the right
    /// place to protect it from being cancelled out from under a caller who
    /// isn't aware an authentication is currently underway.
    func lock() {
        guard !isAuthenticating else { return }
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
            lastError = Self.appError(for: error)
        }
    }

    /// A device that can never authenticate (no passcode, no biometry) is a
    /// settings problem, not a failed attempt: the lock view offers Settings
    /// instead of a retry.
    nonisolated static func appError(for error: Error) -> AppError {
        if let laError = error as? LAError,
           laError.code == .passcodeNotSet || laError.code == .biometryNotAvailable {
            return .authenticationNotAvailable
        }
        return .authenticationFailed(error.localizedDescription)
    }
}
