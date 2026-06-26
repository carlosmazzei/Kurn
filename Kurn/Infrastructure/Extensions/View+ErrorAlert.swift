//
//  View+ErrorAlert.swift
//  Kurn
//
//  Shared error alert presentation. Several screens surface an `AppError` the
//  same way — a localized "Error" alert with an OK button and the error's
//  description — so the modifier lives here instead of being repeated per view.
//

import SwiftUI

extension View {
    /// Present a standard error alert bound to an optional `AppError`. The alert
    /// shows while the binding is non-nil and clears it when dismissed.
    func errorAlert(_ error: Binding<AppError?>) -> some View {
        alert(
            NSLocalizedString("common.error", comment: "Error"),
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: "OK"), role: .cancel) {}
        } message: { presented in
            Text(presented.errorDescription ?? "")
        }
    }
}
