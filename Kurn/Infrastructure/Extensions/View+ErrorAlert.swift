//
//  View+ErrorAlert.swift
//  Kurn
//
//  Shared error dialog presentation. Several screens surface an `AppError` the
//  same way: a localized "Error" dialog with an OK button and the error's
//  description, so the modifier lives here instead of being repeated per view.
//

import SwiftUI

extension View {
    /// Present a standard error dialog bound to an optional `AppError`. The
    /// dialog shows while the binding is non-nil and clears it when dismissed.
    func errorAlert(_ error: Binding<AppError?>) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.warning,
            title: NSLocalizedString("common.error", comment: "Error"),
            message: error.wrappedValue?.errorDescription ?? "",
            primaryTitle: NSLocalizedString("common.ok", comment: "OK"),
            primaryAction: {}
        )
    }
}
