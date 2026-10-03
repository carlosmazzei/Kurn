//
//  SecurityCoverView.swift
//  Kurn
//
//  Content hosted by the security cover window. Renders the privacy placeholder
//  or the lock screen, and owns the Settings escape hatch.
//
//  The escape hatch has to be presented from here rather than from the app's
//  own hierarchy: the cover window sits above everything, so a Settings sheet
//  presented underneath it would be invisible. It exists only for the case
//  where the device has no passcode configured — authentication can then never
//  succeed, and without a way to turn the requirement off the user is locked
//  out of their own library for good (`RecordingAccessGate.offersSettingsEscapeHatch`).
//
//  It is deliberately not the full Settings screen. Anything reachable from
//  here is reachable without authenticating, so it holds the one control the
//  stranded owner needs and nothing that reads meeting content, changes where
//  content is sent, or destroys it.
//

import KurnCore
import SwiftUI

struct SecurityCoverView: View {
    let state: SecurityCoverState
    let gate: RecordingAccessGate
    let settings: AppSettings

    /// Drives the escape hatch. Owned here so `LockedRecordingsView` keeps the
    /// same binding-based button it already had.
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            // Painted unconditionally: a hosting controller's view is not
            // reliably opaque, and a cover that lets content show through is
            // not a cover.
            Theme.background.ignoresSafeArea()

            switch state {
            case .hidden:
                EmptyView()
            case .privacy:
                PrivacyCoverView()
            case .locked:
                LockedRecordingsView(gate: gate, showingSettings: $showingSettings)
                    .task { await gate.authenticate() }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { LockedSettingsView(settings: settings) }
        }
        // Drop the escape hatch when the cover stops being the lock screen.
        // The window is only hidden, never rebuilt, so a `true` left behind
        // here would re-present Settings by itself the next time the app locks.
        .onChange(of: state) { _, newState in
            if newState != .locked { showingSettings = false }
        }
        // Authentication can become possible while the sheet is up (a passcode
        // set in the system Settings meanwhile); the route closes with it.
        .onChange(of: gate.offersSettingsEscapeHatch) { _, offered in
            if !offered { showingSettings = false }
        }
    }
}

/// The only settings reachable from the lock screen: whether to require
/// authentication at all. Shown only on a device with no passcode, where the
/// lock cannot be satisfied and offers no protection to preserve.
private struct LockedSettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.requireAuthForRecordings) {
                    SettingsRowLabel(
                        title: NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                        detail: NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption")
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.title", comment: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
    }
}
