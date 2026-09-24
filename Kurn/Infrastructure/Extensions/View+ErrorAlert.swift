//
//  View+ErrorAlert.swift
//  Kurn
//
//  Shared error dialog presentation. Several screens surface an `AppError` the
//  same way: a localized "Error" dialog with an OK button and the error's
//  description, so the modifier lives here instead of being repeated per view.
//

import SwiftUI
import KurnCore

extension View {
    /// Present a standard error dialog bound to an optional `AppError`. The
    /// dialog shows while the binding is non-nil and clears it when dismissed.
    ///
    /// `onOpenNetworkSettings`, when given, turns a `.networkPolicyRestricted`
    /// failure into a dialog that names the cause and offers the Large
    /// Transfers switches directly: the fix for "blocked on cellular" is a
    /// toggle two screens deep, and a bare OK left the user to find it — or,
    /// worse, to conclude they were offline.
    func errorAlert(
        _ error: Binding<AppError?>,
        onOpenNetworkSettings: (() -> Void)? = nil
    ) -> some View {
        var isNetworkPolicy = false
        if case .networkPolicyRestricted? = error.wrappedValue { isNetworkPolicy = true }
        let offersSettings = isNetworkPolicy && onOpenNetworkSettings != nil
        return kurnDialog(
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            iconSystemName: isNetworkPolicy ? "wifi.exclamationmark" : "exclamationmark.triangle.fill",
            iconTint: Theme.warning,
            title: isNetworkPolicy
                ? NSLocalizedString("error.network_policy_restricted.title", comment: "Wi-Fi required dialog title")
                : NSLocalizedString("common.error", comment: "Error"),
            message: error.wrappedValue?.errorDescription ?? "",
            primaryTitle: offersSettings
                ? NSLocalizedString("error.network_policy_restricted.open_settings", comment: "Open network transfer settings")
                : NSLocalizedString("common.ok", comment: "OK"),
            primaryAction: { if offersSettings { onOpenNetworkSettings?() } },
            secondaryTitle: offersSettings ? NSLocalizedString("common.ok", comment: "OK") : nil
        )
    }
}
