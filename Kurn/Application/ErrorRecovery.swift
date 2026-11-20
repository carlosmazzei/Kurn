//
//  ErrorRecovery.swift
//  Kurn
//
//  The recovery step an error dialog offers for an `AppError`, decided outside
//  `Views/` so the coverage gate measures it.
//

import Foundation
import KurnCore

/// The one next step an error dialog offers, derived from `AppError.recoveryAction`.
struct ErrorRecovery: Equatable {
    enum Destination: Equatable {
        case retry
        /// The app's page in the system Settings app (permissions, passcode).
        case systemSettings
        case screen(ErrorRecoveryScreen)
    }

    let action: AppErrorRecoveryAction
    let destination: Destination

    /// `nil` when the error names no action, or names Retry and the caller
    /// cannot rerun the operation.
    init?(error: AppError, canRetry: Bool) {
        guard let action = error.recoveryAction else { return nil }
        let destination: Destination
        switch action {
        case .retry:
            guard canRetry else { return nil }
            destination = .retry
        case .openSettings:
            switch error {
            // `permissionDenied` is cloud-transcription consent or an engine
            // permission, both granted in Transcription settings. A refused iOS
            // speech recognition permission is granted only in the system
            // Settings app, like a missing passcode.
            case .permissionDenied: destination = .screen(.transcription)
            case .speechRecognitionDenied, .authenticationNotAvailable: destination = .systemSettings
            // Only the caller's `onOpenNetworkSettings` shortcut offers this one:
            // the Transcription screen shows the error with the switches on screen.
            case .networkPolicyRestricted: return nil
            default: destination = .screen(.providers)
            }
        case .freeSpace:
            destination = .screen(.storage)
        case .changeProviderOrModel:
            if case .transcriptionLanguageUnsupported = error {
                destination = .screen(.transcription)
            } else {
                destination = .screen(.summary)
            }
        case .recoverQuarantinedAudio:
            destination = .screen(.health)
        case .exportDiagnostics:
            destination = .screen(.diagnostics)
        }
        self.action = action
        self.destination = destination
    }

    var title: String {
        switch action {
        case .retry: NSLocalizedString("error.recovery.retry", comment: "Error dialog button that reruns the failed operation")
        case .openSettings: NSLocalizedString("error.recovery.open_settings", comment: "Error dialog button that opens the settings fixing the error")
        case .freeSpace: NSLocalizedString("error.recovery.free_space", comment: "Error dialog button that opens Storage settings")
        case .changeProviderOrModel: NSLocalizedString("error.recovery.change_model", comment: "Error dialog button that opens the provider/model settings")
        case .recoverQuarantinedAudio: NSLocalizedString("error.recovery.recover_audio", comment: "Error dialog button that opens Health & Recovery")
        case .exportDiagnostics: NSLocalizedString("error.recovery.export_diagnostics", comment: "Error dialog button that opens Diagnostics")
        }
    }
}

/// A settings screen an error dialog can open in a sheet (`View+ErrorAlert.swift`).
enum ErrorRecoveryScreen: String, Identifiable {
    case providers, transcription, summary, storage, health, diagnostics

    var id: String { rawValue }
}
