//
//  View+ErrorAlert.swift
//  Kurn
//
//  Shared error dialog presentation. Several screens surface an `AppError` the
//  same way: a localized "Error" dialog with the error's description, so the
//  modifier lives here instead of being repeated per view. When the error names
//  a recovery action (`AppError.recoveryAction`), the dialog offers it as its
//  primary button beside OK.
//

import SwiftUI
import UIKit
import KurnCore

extension View {
    /// Present a standard error dialog bound to an optional `AppError`. The
    /// dialog shows while the binding is non-nil and clears it when dismissed.
    ///
    /// The primary button is the error's recovery action when one applies:
    /// Try Again (only when `onRetry` is given, since only the caller knows
    /// what to rerun), or a button opening the settings screen that fixes it
    /// (`ErrorRecovery`). Screens that are themselves that destination pass
    /// `offersRecovery: false`.
    ///
    /// `onOpenNetworkSettings`, when given, turns a `.networkPolicyRestricted`
    /// failure into a dialog that names the cause and offers the Large
    /// Transfers switches directly: the fix for "blocked on cellular" is a
    /// toggle two screens deep, and a bare OK left the user to find it — or,
    /// worse, to conclude they were offline.
    func errorAlert(
        _ error: Binding<AppError?>,
        offersRecovery: Bool = true,
        onRetry: (() -> Void)? = nil,
        onOpenNetworkSettings: (() -> Void)? = nil
    ) -> some View {
        modifier(ErrorAlertModifier(
            error: error,
            offersRecovery: offersRecovery,
            onRetry: onRetry,
            onOpenNetworkSettings: onOpenNetworkSettings
        ))
    }
}

extension ErrorRecoveryScreen {
    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .providers: ProvidersSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .summary: SummarySettingsView()
        case .storage: StorageSettingsView()
        case .health: HealthRecoveryView()
        case .diagnostics: DiagnosticsSettingsView()
        case .privacy: PrivacyCloudSettingsView()
        case .knowledge: KnowledgeSettingsView()
        }
    }
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var error: AppError?
    let offersRecovery: Bool
    let onRetry: (() -> Void)?
    let onOpenNetworkSettings: (() -> Void)?

    @State private var screen: ErrorRecoveryScreen?
    @Environment(\.openURL) private var openURL
    // Injected again on the sheet: Storage reads it, and a sheet presented
    // from inside a navigation stack may not inherit it (see `SettingsView.link`).
    @Environment(ModelDownloadController.self) private var downloads: ModelDownloadController?

    func body(content: Content) -> some View {
        var isNetworkPolicy = false
        if case .networkPolicyRestricted? = error { isNetworkPolicy = true }
        let networkShortcut = isNetworkPolicy ? onOpenNetworkSettings : nil
        let recovery = networkShortcut == nil && offersRecovery
            ? error.flatMap { ErrorRecovery(error: $0, canRetry: onRetry != nil) }
            : nil
        let offersAction = networkShortcut != nil || recovery != nil
        let primaryTitle = if networkShortcut != nil {
            NSLocalizedString("error.network_policy_restricted.open_settings", comment: "Open network transfer settings")
        } else if let recovery {
            recovery.title
        } else {
            NSLocalizedString("common.ok", comment: "OK")
        }

        return content
            .kurnDialog(
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                iconSystemName: isNetworkPolicy ? "wifi.exclamationmark" : "exclamationmark.triangle.fill",
                iconTint: Theme.warning,
                title: isNetworkPolicy
                    ? NSLocalizedString("error.network_policy_restricted.title", comment: "Wi-Fi required dialog title")
                    : NSLocalizedString("common.error", comment: "Error"),
                message: error?.errorDescription ?? "",
                primaryTitle: primaryTitle,
                primaryAction: {
                    if let networkShortcut {
                        networkShortcut()
                    } else if let recovery {
                        perform(recovery)
                    }
                },
                secondaryTitle: offersAction ? NSLocalizedString("common.ok", comment: "OK") : nil
            )
            .sheet(item: $screen) { screen in
                NavigationStack {
                    screen.content
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(NSLocalizedString("common.done", comment: "Done")) {
                                    self.screen = nil
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .environment(downloads)
            }
    }

    private func perform(_ recovery: ErrorRecovery) {
        switch recovery.destination {
        case .retry:
            onRetry?()
        case .systemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .screen(let destination):
            screen = destination
        }
    }
}
